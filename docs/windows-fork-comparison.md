---
title: 次世代ターミナルエミュレータ「Ghostty」のWindowsネイティブ実装
tags: Terminal ghostty ZIG
author: spumoni
slide: false
---
<!--
元記事: https://qiita.com/spumoni/items/efef9da31a5012843ec1 (2026-10-08 取得の Markdown 原文)
keylimesoda/ghostty に関する追記は、ローカルの D:\home\source\zig\keylimesoda\ghostty
(main = 4653f2c24、2026-03-22。上流との差分 31 ファイル +2034/-119、基点 1d54a94ce)と
GitHub Releases(最新 v1.3.1-windows.3、2026-03-22)から確認した。ビルド・実行による動作確認はしていない。
-->
https://github.com/fukuyori/ghostty

### 1. プロジェクトの目的と概要

[Ghostty](https://ghostty.org/) はZig言語で実装された、高速かつ機能豊富なGPUアクセラレーション対応ターミナルエミュレータです。公式アップストリーム（`ghostty-org/ghostty`）におけるWindowsネイティブ対応は開発途上のステータスにあります。

その後、公式アップストリームは方針を明確にしました。2026年10月10日、メンテナの Mitchell Hashimoto 氏は、Ghostty 本体を再び Windows でビルド・テストできるようにする PR（[#14608](https://github.com/ghostty-org/ghostty/pull/14608)、マージされずにクローズ）に次のようにコメントしています。

- Ghostty 本体（core）の Windows 対応は、もう優先事項ではない。
- 今後の正しい道は、`libghostty-vt` と、それを使った独自の Windows ビルドである。`libghostty-vt` はすでに Windows でテストしている。
- core の Windows テストを外したのは意図的である。
- どうしても Windows で Ghostty の GUI を使いたい場合は、プロジェクトをフォークするのが適切な対応である。

実際、公式アップストリームの `src/apprt/` に Windows 用のランタイムはなく、#14608 の説明によれば、2026年9月の GTK 描画の変更（[#14052](https://github.com/ghostty-org/ghostty/pull/14052)）以降、Ghostty 本体は Windows でコンパイルできていません。一方で、`libghostty-vt` の Windows 対応（DLL 対応など）は引き続き進められています。Windows で GUI 版の Ghostty を使うには、Goozttyを含む各フォークを利用することになります。

なお、公式アップストリームではAIの濫用に対する制限が厳密に定められており、PRやIssueの作成を含め厳格な運用ポリシーが存在します。GoozttyではアップストリームへのPRやIssue作成を行わない運用をとっています。

本プロジェクト（[`fukuyori/gooztty`](https://github.com/fukuyori/ghostty) / `windows` ブランチ）は、バイブコーディングによって進められており、サードパーティ製のGUIフレームワークを使用せず、Win32 API および Direct3D 11 (D3D11) / DirectComposition を直接用いたWindowsネイティブ移植を行っています。

本実装では、Phase 1（基本ランタイム・IME追従）から Phase 6（リリーススクリプト完備）までのロードマップを実装済みです。専用ConPTYホストの同梱による Kitty Graphics Protocol（画像表示）対応、日本語IMEのカーソル位置インライン追従、Win32ネイティブのタブバー、画面分割線のマウスドラッグ操作、マルチモニターDPI（Dynamic DPI）追従、ハイコントラスト対応、および Inno Setup インストーラー作成スクリプト（`build-installer.ps1`）が含まれます。

本稿では、Goozttyの内部構造を起点とし、コミュニティ内の先行・関連移植フォーク（`noctty`、`liamsmith86/ghostty-windows`、`zcg/ghostty-win`、`mattn/ghostty`、`keylimesoda/ghostty`、`deblasis/wintty`）および既存の主要Windowsターミナル製品（Windows Terminal、Alacritty、WezTerm）とのコードレベル・システムアーキテクチャレベルの詳細比較分析を行います。

---

### 2. Ghosttyの内部設計とGoozttyのアーキテクチャ構成

Ghosttyのコードベースは、VTエスケープシーケンス解釈、内部グリッドバッファ、グリフアトラス生成といったプラットフォーム共通のコアロジック（`src/terminal/` や `src/font/`）と、各OSのウィンドウ生成・描画・イベントループを担うランタイム抽象化層（`apprt`）が明確に分離された構造をとっています。

- `src/apprt/embedded.zig`：macOS向け（AppKit、Metal）
- `src/apprt/gtk.zig`：Linux向け（GTK4、Wayland/X11）
- `src/apprt/win32/`：Windowsネイティブ向け（Win32 API、Direct3D 11）

本プロジェクト（`fukuyori/gooztty`）では、公式のアーキテクチャ設計にそのまま適合させるため、Win32ランタイムロジックを `src/apprt/win32/` ディレクトリ配下にモジュール化して整理し、コアとの境界を極めてクリーンに保っています。

#### 主要モジュール構成

- **`App.zig`**：アプリケーションライフサイクル、メッセージ専用ウィンドウ（`GhosttyWakeup` / `HWND_MESSAGE`）によるモーダルループ内での非同期メッセージディスパッチ、GPUリセット・スリープ復帰に対応するバックオフ付き自動復旧機構（GPU Recovery / Power Resume）の管理。
- **`Window.zig` / `Surface.zig` / `Tab.zig`**：`Window -> Tab -> Surface/SplitTree` という明確なオブジェクト所有権階層の構築。
- **`TabBar.zig` & `TabBarAccessibility.zig`**：素のWin32 APIで描画されるネイティブタブバー。タブのドラッグ並べ替え、マウスホイール切替、ダブルクリックでのインライン名変更ダイアログ、オーバーフロー時左右スクロール、MSAA（Microsoft Active Accessibility）対応。
- **`SplitTree.zig`**：Ghosttyコアのサーフェス分割ツリーと連動した、画面分割線のホバー表示・マウスドラッグリサイズ（`GhosttySplitDivider` レイヤードウィンドウ）・最小セルサイズ制約・Split Zoom表示。
- **`DirectComposition.zig` & `Backdrop.zig` / `GaussianBlur.zig`**：DirectComposition Visualツリーを介した描画スワップチェーンの合成と、`background-opacity`（背景透過）およびDWM効果の制御。

外部の重厚なUIフレームワーク（Electron, WinUI, SDL, GLFW等）を挟まず、OS標準のC-ABI（Win32 API）とZig標準ライブラリのみで構成されているため、公式アップストリームの更新を取り込みやすい高い追従性を確保しています。

---

### 3. 他のWindows移植フォークとのコードレベル詳細比較

コミュニティ内で先行・関連する主要フォークと本プロジェクト（`fukuyori/gooztty`）の技術仕様の比較です。

#### フォーク実装の技術比較表

| 項目 | `fukuyori/gooztty` | `noctty` | `liamsmith86/ghostty-windows` | `zcg/ghostty-win` | `mattn/ghostty` (参考参照元) | `keylimesoda/ghostty` | `deblasis/wintty` |
| -------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------- | ------------------------------------------- | -------------------------------- | ----------------------------- | ----------------------------- | ----------------------------------- |
| 描画API | Direct3D 11 + DirectComposition (一部OpenGL互換可) | OpenGL (WGL 4.3+) | OpenGL (WGL) | Direct3D 11 / Direct2D | OpenGL (WGL) | OpenGL (WGL、GTK4 経由) | Direct3D 12 (Pro Legacy は Direct3D 11) |
| コード構成 | `src/apprt/win32/` 配下に機能別モジュール設計 | 独自外付けランタイム | `src/apprt/win32.zig` 単一ファイル拡張 | 独自エントリポイント統合 | 初期Win32実装プロトタイプ | 本家 GTK apprt を流用 | libghostty を C# / WinUI 3 から利用 |
| ConPTY統合 | OpenConsole / `conpty.dll` 同梱 (Kitty Graphics Protocol の画像表示に対応) | OpenConsole 同梱 + in-box フォールバック (Kitty Graphics Protocol の画像表示に対応) | `kernel32.dll` in-box ConPTY (非同期パイプ) | `kernel32.dll` in-box ConPTY | `kernel32.dll` in-box ConPTY | OpenConsole 同梱 + in-box フォールバック + 直接パイプ | OpenConsole / `conpty.dll` 同梱 (Kitty Graphics Protocol / Sixel 対応) |
| タブ・画面分割 | ネイティブWin32 TabBar & マウスドラッグ分割線 | ネイティブWin32 タブ・分割 + セッション保存/復元 | オーナー描画タブ (初期実験) | 基礎的単一〜複数Surface | 基礎的単一Surface | GTK4 / libadwaita のタブ・分割 | WinUI 3 の縦タブ・分割、クイックターミナル |
| IME対応 | `ImmSetCompositionWindow` カーソル位置完全インライン追従 | `ImmSetCompositionWindow` 連動 | `ImmAssociateContextEx` 連動 | DirectWrite連携 | 基本文字入力のみ | GTK IMContext 任せ | WinUI 3 / Windows テキスト入力経由 (個別検証情報なし) |
| DPI / アクセシビリティ | Dynamic DPI 完全追従 + ハイコントラスト + MSAA | Per-monitor DPI + UI Automation (一部) | 基本DPI対応 | DWMスケール依存 | 基本DPI対応 | GTK4 任せ | WinUI 3、ハイコントラスト対応 (README記載) |
| パッケージング | インストーラー | インストーラー (`-setup.exe`) & ポータブル (`.zip`) / Scoop / WinGet | マニュアルビルド (リリースなし) | 単体バイナリ配布 (`ghostty.exe`) | ポータブルアーカイブ (`.zip`) | ポータブル (`.zip`) | OSS ビルド / スポンサー版 MSIX 等 (提供形態はティア別) |
| 特有の付加機能 | D3D11透過/Backdrop/Blur、GPU復旧耐性、タブ名変更ダイアログ | コマンドパレット、設定GUI、シェルピッカー、自動更新 | なし（最小限の拡張） | DirectWriteフォント描画実験 | 最小限の初期実装 | ペインのシェル切替、子プロセス一括終了 | 設定UI、プロファイル自動検出、セッション復元、Windows通知・ジャンプリスト |
| 最終更新日 (UTC) | 2026-10-25 | 2026-10-25 | 2026-03-14 | 2026-08-11 | 2026-04-07 | 2026-03-22 | 2026-10-24 |

※ 最終更新日は 2026-10-25 時点に GitHub の既定ブランチで確認した最新コミットのコミッター日付 (UTC) です。

#### 詳細なコード差分分析

#### 1. ウィンドウ生成、メッセージループ、および GPU リセット耐性

- **`fukuyori/gooztty`**：
  `RegisterClassExW` で `GhosttyWindow`、`GhosttyTabBar`、`GhosttySplitDivider`、およびメッセージ専用の `GhosttyWakeup` ウィンドウクラスを生成します。`WndProc` 内で受け取ったイベントを即座にGhosttyコアへ伝達するだけでなく、D3D11デバイスの消失（GPUドライバクラッシュやスリープ復帰等）を検知した際に、バックオフアルゴリズムを伴う安全な自動復旧ロジック（`gpu_recovery_max_cycles`）を `App.zig` 内で駆動させます。
- **`noctty`**：
  バックグラウンドでのセッション管理、UI Automation、ホットキーフック、外部メッセージ受信を処理するため、`WndProc` の手前に独自メッセージキューとディスパッチャを挟み込む構成をとっています。
- **その他フォーク (`liamsmith86` / `zcg` / `mattn`)**：
  標準的な `WndProc` による基本的なメッセージディスパッチにとどまり、GPUロスト復旧やモーダルループ中のメッセージ待避構造は持ちません。
- **`keylimesoda/ghostty`**：
  ウィンドウ生成とメッセージループは GTK4（MSYS2 mingw64 ビルド）に任せ、Win32 API を直接は扱いません。Windows 向けの変更は主にタイミング面で、`timeBeginPeriod(1)` でタイマー分解能を 1ms にしています。また、GLib の `MainContext` をノンブロッキングで回し、イベントがないときは 1ms スリープします。さらに tick コールバックで GTK のフレームクロックを止まらないようにしています。GPU ロストからの復旧処理は、本家との差分には見当たりません。
- **`deblasis/wintty`**：
  C# / WinUI 3 のアプリがウィンドウ、入力、Windows 統合を担当し、Ghostty の `libghostty` を P/Invoke で呼び出します。Win32 の `WndProc` を中心に組み立てる Gooztty とは異なり、Windows UI とアプリのライフサイクルは WinUI 3 を軸に構成されています。

#### 2. 疑似コンソール（ConPTY）と Kitty Graphics Protocol の画像データ透過

- **`fukuyori/gooztty` & `noctty`**：
  Windows標準（`kernel32.dll`）の in-box ConPTY は、Kitty Graphics Protocol で使われる APC エスケープシーケンス（画像データ）を削ぎ落としてしまう既知の制約があります。そのため、両プロジェクトともに外部の最新 OpenConsole ホスト（`conpty.dll` / `OpenConsole.exe`）を同梱・バインドし、シーケンスを透過して Kitty Graphics Protocol の画像を表示できるようにしています。
- **その他フォーク (`liamsmith86` / `zcg` / `mattn`)**：
  OS標準の `kernel32.dll` ConPTY に直接接続しているため、テキスト入出力は機能するものの、Kitty Graphics Protocol の画像データを含む APC シーケンスが ConPTY 層で破棄されます。
- **`keylimesoda/ghostty`**：
  `OpenConsole.exe` を同梱しますが、`conpty.dll` は使いません。`src/os/conpty.zig` で Windows Terminal の `winconpty.cpp`（`_CreatePseudoConsole`）と同じ手順を自前で実装しています。`NtCreateFile` で `\Device\ConDrv\Server` と `\Reference` を開き、`OpenConsole.exe --headless` を起動する方式です。リサイズはシグナルパイプに `PTY_SIGNAL_RESIZE_WINDOW` を直接書き込んで伝えます。`OpenConsole.exe` を使えない場合は、`kernel32.dll` の `CreatePseudoConsole` にフォールバックします。加えて、設定 `windows-backend`（`auto` / `conpty` / `direct-pipe`）で、ConPTY を経由せず子プロセスの標準入出力を直接つなぐモードも選べます。`auto` のときは WSL だけが直接パイプになります。
- **`deblasis/wintty`**：
  `Microsoft.Windows.Console.ConPTY` パッケージ由来の `conpty.dll` と `OpenConsole.exe` を同梱する構成で、プロジェクトファイルは対象 RID のファイルが欠けているとビルドを失敗させます。一方、実行時の `resolvePseudoConsoleApi` は DLL のロードや必要なエクスポート取得に失敗すると in-box `kernel32.dll` にフォールバックし、その場合 Kitty Graphics Protocol / Sixel が使えないことを警告ログに記録します。

#### 3. グラフィックススタックとシェーダーパイプライン

- **`fukuyori/gooztty`**：
  Windows ネイティブの Direct3D 11 レンダラー（`src/renderer/D3D11.zig`）および DirectComposition を採用しています。Kitty Graphics Protocol の画像レンダリング時の頂点シェーダーz座標クリッピングバグ（`ortho2d` 変換で z=-1 となり描画消失する問題）を修正済みであり、`background-opacity` によるウィンドウ背景の透過合成や、DirectComposition Visual ツリーを用いた Backdrop / Gaussian Blur の実験的実装を含みます。
- **`noctty`**：
  Ghostty 本家の OpenGL (WGL 4.3+) パイプラインを継続利用しています。背景の不透明度調整（`background-opacity`）は動作しますが、DWM による背景ブラー効果（`background-blur`）は現行実装では無効（inert）となっています。
- **`zcg/ghostty-win`**：
  Direct3D 11 / Direct2D への移行を図り、フォントレンダラーを DirectWrite に置き換えていますが、本家（FreeType/HarfBuzz）のグリフキャッシュ設計と大きく乖離するため、アップストリーム更新の追従コストが高くなっています。
- **`keylimesoda/ghostty`**：
  本家の OpenGL レンダラーを GTK4 の GLArea 上でそのまま使います。ただし Windows では GTK のフレームクロックに頼らず、`wglGetCurrentDC` と `SwapBuffers` で直接 present します。最短 8ms 間隔に抑えているので、上限は約 120 FPS です。また Windows の SRWLOCK は公平でないため、IO スレッドが 8ms ごとに 1ms 譲り、レンダラースレッドがロックを取れないまま待たされないようにしています。フォントは FreeType + HarfBuzz ですが、Windows では fontconfig を使わないので、システムフォントの探索はしません（`src/font/backend.zig` のコメントによる）。
- **`deblasis/wintty`**：
  レンダラーは Direct3D 12 で、HWND、WinUI の `SwapChainPanel`、共有テクスチャの3つの表示経路を実装しています。README によると OSS / Sponsor 版は Windows 11 x64 と DX12 feature level 12.0 対応GPUを必要とし、ソフトウェア描画へのフォールバックはありません。Pro Legacy ティアには D3D11 レンダラーと WARP ソフトウェア描画が用意されています（いずれもREADME記載で、このローカルコード確認では検証していません）。

#### 4. タブ・画面分割・UI 機能

- **`fukuyori/gooztty`**：
  素の Win32 API によるネイティブ TabBar（ドラッグ並べ替え、マウスホイール切替、ダブルクリックでの名変更ダイアログ、オーバーフロー時スクロールボタン）と、画面分割線のマウスドラッグリサイズ（レイヤードウィンドウ描画、ホバー判定、最小セル制約）を完備。Ghostty コアの `SplitTree` と密接に統合されています。
- **`noctty`**：
  ネイティブタブ・画面分割に加え、セッションの永続化保存・復元（`session-state.json`）、コマンドパレット、シェルピッカー（PowerShell / cmd / Git Bash / WSL の選択起動）、設定GUIなど、外付けの付加機能を幅広く実装しています。
- **`keylimesoda/ghostty`**：
  タブ・画面分割・コマンドパレットは、本家 GTK 版（libadwaita）の機能をそのまま使います。Windows 向けには次の機能を追加しています。
  - ペインの右クリックメニュー「Change Shell」で、そのペインのシェルを差し替える（PowerShell 7 / PowerShell 7 Direct / Windows PowerShell / CMD / WSL）。
  - コマンドパレットの「New Tab (…)」で、シェルを選んで新しいタブを開く。
  - 分割したペインに親ペインのシェルを引き継ぐ。
  - 既定のシェルを `pwsh.exe` → `powershell.exe` → `cmd.exe` の順に探す。
  - 終了時に Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）で子プロセスもまとめて終了させる。
- **`deblasis/wintty`**：
  実装には WinUI 3 の縦タブと画面分割、クイックターミナル、コマンドパレット、設定画面、シェル検出を含むプロファイル管理、セッション保存・復元があります。通知、ジャンプリスト、タスクバー進捗、Mica / Acrylic / Crystal 背景にも対応するコードを確認しました。

#### 5. IME（日本語入力）・DPI・アクセシビリティ統合

- **`fukuyori/gooztty`**：
  `WM_IME_*` をトラップし、ターミナル内のグリッドセル座標からピクセル座標を換算して `ImmSetCompositionWindow` (`CFS_POINT` / `CFS_RECT`) を呼び出すことで、IME 変換候補ウィンドウをカーソル直下に完全インライン追従させます。また、マルチモニター間の Dynamic DPI 追従（`WM_DPICHANGED`）、Windows ハイコントラストモード連動、MSAA 経由でのタブ要素公開（`TabBarAccessibility.zig`）を実装しています。
- **`noctty`**：
  IME 入力および Per-monitor DPI スケーリングに対応し、UI Automation 経由でのコントロール公開を進めています。
- **`keylimesoda/ghostty`**：
  IME は本家 GTK 版と同じく、`gtk.IMMulticontext` の `setCursorLocation` でカーソル位置を伝える方式です。Windows 固有の IME 処理は加えていません。DPI とアクセシビリティも GTK4 に任せており、Windows 向けの追加はありません。Windows 上での実際の動作は確認していません。
- **`deblasis/wintty`**：
  WinUI 3 の入力経路を使います。IME の候補位置追従など個別の挙動は、ローカル資料からは確認できず、この比較でも実機検証していません。README には Windows ハイコントラスト対応が記載されていますが、アクセシビリティ機能の詳細や実機での確認結果は比較対象に含めていません。

#### 総合評価

上の比較表と詳細分析の内容をもとにした評価です。実際に動かして比べたものではありません。

| フォーク | 位置づけ | 強み | 弱み |
| --- | --- | --- | --- |
| `fukuyori/gooztty` | Windows 統合を重視したネイティブ実装 | Kitty Graphics Protocol の画像表示、IME追従、DPI/アクセシビリティ、GPU復旧 | Win32/D3D11 層を自前で保守、アルファ版 |
| `noctty` | 付加機能の多い実用志向の実装 | セッション復元、設定GUI、自動更新、配布形態が豊富 | 背景ブラー無効、UI Automation は一部 |
| `liamsmith86/ghostty-windows` | 単一ファイルの軽量実装 | 構成が単純 | ConPTY経由ではKitty Graphics Protocol の画像を表示できない、タブは実験段階 |
| `zcg/ghostty-win` | DirectWrite 描画の実験 | D3D11/D2D + DirectWrite | 本家との乖離で追従コスト大、ConPTY経由ではKitty Graphics Protocol の画像を表示できない |
| `mattn/ghostty` | 初期プロトタイプ (参考実装) | 参照元として簡潔 | 単一Surface、IMEは基本入力のみ |
| `keylimesoda/ghostty` | 本家 GTK 版の Windows 移植 | 本家との差分が小さい、GTK版の機能をそのまま使える | GTK4 の DLL 同梱が必要、IME/DPI は GTK 任せ |
| `deblasis/wintty` | WinUI 3 シェルと libghostty を組み合わせた Windows アプリ | 機能豊富な設定・プロファイル・セッション管理、DX12 レンダラー、Kitty Graphics Protocol / Sixel 対応 | OSS / Sponsor 版は Windows 11 と DX12 GPU が必要、Pro Legacy 以外にソフトウェア描画フォールバックなし（README記載）。libghostty の C API は未バージョン（README記載） |

各フォークの方針は、大きく3つに分かれます。

- **Win32 を直接使い、Windows との統合を作り込む**: Goozttyと `noctty` です。どちらも OpenConsole を同梱して Kitty Graphics Protocol の画像データを通し、IME と DPI にも個別に対応しています。Goozttyは IME のインライン追従、Dynamic DPI、MSAA、GPU 復旧といった OS との統合を重視しています。`noctty` はセッション復元、設定 GUI、自動更新など、アプリとしての付加機能を重視しています。
- **本家の GTK 版をそのまま Windows で動かす**: `keylimesoda/ghostty` です。本家との差分が 31 ファイルと小さく、本家の更新を取り込みやすい構成です。タブ・分割・コマンドパレットも GTK 版のものをそのまま使えます。その代わり、IME・DPI・アクセシビリティは GTK4 の Windows 対応しだいで、Windows 向けの作り込みはしていません。
- **初期の実験・プロトタイプ**: `liamsmith86/ghostty-windows`、`zcg/ghostty-win`、`mattn/ghostty` です。いずれも in-box ConPTY に直接つなぐため、Kitty Graphics Protocol の画像は表示できません。日常的に使うより、実装を参照する用途に向いています。
- **WinUI 3 シェルで機能をまとめる**: `deblasis/wintty` です。libghostty を活用しながら、DX12 描画と縦タブ、設定・プロファイル・セッション管理を備えます。Windows 11 と GPU 要件があるため、対応環境を確認して選ぶ必要があります。

日本語 IME のカーソル位置追従と Windows ネイティブ統合を重視するなら Gooztty、WinUI 3 の設定・プロファイル・セッション機能を重視するなら `deblasis/wintty`、付加機能と配布形態を重視するなら `noctty` が候補になります。

---

### 4. 既存の主要Windowsターミナル製品との比較分析

Windows環境で広く利用されている代表的なターミナル製品（Windows Terminal、Alacritty、WezTerm）と、Goozttyの構造的な違いを技術的観点から比較します。

#### プロダクト技術仕様比較表
| 項目 | `fukuyori/gooztty` | Windows Terminal | Alacritty | WezTerm |
| ---------------------- | -------------------------------------- | ----------------------------- | ------------------------------ | --------------------------------- |
| 実装言語 | Zig | C++ / C# (WinRT) | Rust | Rust |
| GUIスタック | 純Win32 API + DirectComposition | WinUI 2 / XAML Islands | winit (Win32抽象化層) | 独自ウィンドウ層 (`window` crate) |
| 描画API | Direct3D 11 | Direct3D 11 (DirectWrite/D2D) | OpenGL | WebGPU / OpenGL |
| フォントエンジン | FreeType + HarfBuzz | DirectWrite | Crossfont (DirectWrite) | HarfBuzz + FreeType / DirectWrite |
| タブ・画面分割 | ネイティブWin32 UI + 内蔵SplitTree | XAMLタブ・分割コントロール | なし（tmux等の外部ツール前提） | 独自GUI描画タブ・分割 |
| 設定方式 | プレーンテキスト (`config.ghostty`) | JSONファイル + GUI設定画面 | TOMLファイル | Luaスクリプト |
| 画像プロトコル | Kitty Graphics Protocol 対応 | なし（Sixel実験的対応） | なし | Sixel, iTerm2, Kitty Graphics Protocol 互換 |
| 実行フットプリント | 超軽量・即時起動 | XAML/WinRT初期化コストあり | 軽量 | Lua/各種依存クレートにより重厚 |
| 最終更新日 (UTC) | 2026-10-25 | 2026-10-23 | 2026-10-16 | 2026-10-10 |

※ 最終更新日は 2026-10-25 時点に GitHub の既定ブランチで確認した最新コミットのコミッター日付 (UTC) です。

#### 各プロダクトとの詳細比較

#### 1. vs Windows Terminal

- **GUIアーキテクチャと起動速度**：
  Windows Terminal は WinUI（XAML Islands）を採用しており、OS標準のタブデザインやアクセシビリティに適合する反面、XAMLランタイムの初期化オーバーヘッドや関連DLLのロード負荷が発生します。本実装はXAMLを一切介さず、素の Win32 ウィンドウ上に D3D11 / DirectComposition を直接構築するため、プロセスの起動とリソース消費が非常に軽量です。
- **機能拡張性と画像描画**：
  Windows Terminal のテキスト描画は DirectWrite に依存しており、画像表示プロトコルのサポートが限定的です。本実装は Ghostty コアの高性能シェーダーにより、Kitty Graphics Protocol などの拡張仕様をネイティブに高速ラスタライズできます。

#### 2. vs Alacritty

- **設計思想と UI 機能の統合**：
  Alacritty は「単一サーフェス描画の速度を追求し、タブや画面分割は外部ツール（tmux等）に委ねる」という思想のもと、Rustの汎用抽象化ライブラリ（winit）を使用しています。本実装（Ghostty）は、コア内部に強力な `SplitTree` サーフェス管理機構を備えており、Windowsネイティブの TabBar や画面分割線のマウスドラッグリサイズを外部ツールなしで快適に操作できます。

#### 3. vs WezTerm

- **ランタイムオーバーヘッドとコンパイル・バイナリサイズ**：
  WezTerm は組み込み Lua エンジンによる高度なスクリプト拡張性を備えていますが、Luaランタイムや多数の重厚な依存クレートをリンクするため、バイナリサイズが大きく、起動・実行時のフットプリントが増大します。本実装は Zig の静的メモリ管理と C-ABI 直接呼び出しで完結しているため、動的スクリプトエンジンのロードなしに最小限のフットプリントと高速なレスポンスを実現しています。

---

### 5. 本実装（fukuyori/gooztty）の技術的特徴

1. **公式アップストリームへの極めて高い追従性**
   Win32/D3D11固有の処理を `src/apprt/win32/` 配下に完璧に分離・モジュール化しているため、公式リポジトリのコアロジック更新（VTパーサー改善、エスケープシーケンス機能拡張、Zigコンパイラバージョン更新等）に対するマージ摩擦が最小限に抑えられています。
2. **Direct3D 11 + DirectComposition によるネイティブ描画**
   Windows の標準グラフィックスAPIである D3D11 をネイティブ駆動し、DirectComposition 経由でスワップチェーンを合成。`background-opacity` による完璧なウィンドウ透過処理を実現しています。
3. **OpenConsole 同梱による完全な Kitty Graphics Protocol サポート**
   `kernel32.dll` の ConPTY 制限を回避するため、専用ビルド/パッケージング処理の中で OpenConsole/`conpty.dll` を自動的に取得・配置し、ターミナル内での高品位な画像表示をサポートします。
4. **Windows デスクトップ環境への深い統合**
   日本語 IME 変換候補のインライン追従、マルチモニター異体 DPI（Dynamic DPI）自動スケール、Windows ハイコントラストモード対応、MSAA アクセシビリティ通知など、Windows ユーザーが期待するOS統合品質を達成しています。
5. **ポータブル版および Inno Setup インストーラーの自動生成**
   `scripts/build-release.ps1` によるワンクリックリリースビルドに加え、`scripts/build-installer.ps1` により `signtool.exe` 署名対応の Inno Setup インストーラー（`.exe`）を再現性高く生成可能です。

---

### 6. 完成度

本移植プロジェクトは、`docs/windows-roadmap.md` に定義されたすべての Phase（Phase 1〜6）を **100% 達成** しており使用可能な状態です。しかし、まだ不具合や改善点は残っており、アルファ版の位置付けとなっています。

---

### リンク

- `fukuyori/gooztty`：https://github.com/fukuyori/ghostty
- 公式アップストリーム (`ghostty-org/ghostty`)：https://github.com/ghostty-org/ghostty
- `noctty`：https://github.com/amanthanvi/noctty
- `liamsmith86/ghostty-windows`：https://github.com/liamsmith86/ghostty-windows
- `zcg/ghostty-win`：https://github.com/zcg/ghostty-win
- `mattn/ghostty`：https://github.com/mattn/ghostty
- `keylimesoda/ghostty`：https://github.com/keylimesoda/ghostty
- `deblasis/wintty`：https://github.com/deblasis/wintty
