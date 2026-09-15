# Ghostty Windows版 利用ガイド

この文書は、このフォークのネイティブWindows版をビルドして利用するための
設定、操作、既知の制限をまとめたものです。Windows版は開発中であり、配布形式と
リリース判定はまだ確定していません。

## ビルドと起動

Debugビルド:

```powershell
zig build
./zig-out/bin/ghostty.exe
```

ポータブルなReleaseビルド:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/ghostty.exe
```

Releaseスクリプトは実行ファイルとリソースを配置しますが、アーカイブや
インストーラーは作成しません。ビルド後にPE形式、CPU形式、Windows GUI
サブシステム、CLIとWindowsの版情報、埋め込みアイコングループと大・小アイコン、
シェル統合、テーマ、ファイルサイズ、SHA-256を検証して表示します。

バージョンを変更するときの正本、条件付き更新箇所、Release検証手順は
[バージョン更新チェックリスト](version-update-checklist.md)を参照してください。
コマンドラインのバージョン表示と、Windowsファイルプロパティの
`FileVersion`、`ProductVersion` には同じビルドバージョンが入ります。

## 設定ファイル

標準の設定ファイルは次の場所です。

```text
%LOCALAPPDATA%\ghostty\config.ghostty
```

`XDG_CONFIG_HOME` が設定されている場合は、こちらが優先されます。

```text
%XDG_CONFIG_HOME%\ghostty\config.ghostty
```

拡張子のない旧形式の `ghostty\config` も読み込みます。両方が存在する場合は
旧形式を先に、新しい `config.ghostty` を後から読み込むため、後者の設定が優先
されます。

設定関連の既定キー:

| キー | 操作 |
|---|---|
| `Ctrl+,` | 設定ファイルを開く |
| `Ctrl+Shift+,` | 設定を再読み込みする |

コマンドラインからも設定を確認できます。

```powershell
./zig-out/bin/ghostty.exe +validate-config
./zig-out/bin/ghostty.exe +show-config
./zig-out/bin/ghostty.exe +list-keybinds
```

## 起動診断ログ

通常のGUI起動では標準エラーが画面に表示されません。起動失敗や初期化エラーを
調べる場合は、診断用スクリプトから起動します。

```powershell
./scripts/run-windows-diagnostics.ps1
```

既定ではログを `zig-out\logs` に保存し、起動したプロセスIDとログの絶対パスを
表示します。Ghosttyを終了するまで待ち、終了コードも取得する場合は次のように
実行します。

```powershell
./scripts/run-windows-diagnostics.ps1 -Wait
```

特定のCLI操作を診断する場合は `AdditionalArguments` を使用します。

```powershell
./scripts/run-windows-diagnostics.ps1 `
    -AdditionalArguments @('+validate-config') `
    -Wait
```

ログには設定値、パス、実行したプログラムに由来する情報が含まれる可能性が
あります。共有する前に内容を確認してください。

## ウィンドウ状態の回帰確認

Release実行ファイルの文字入力とコマンド実行、設定再読込、複数ウィンドウの
作成・移動・表示切り替え・終了、混在DPIモニター追従、分割境界、最大化、
最小化、復元、正常終了をまとめて確認できます。

```powershell
./scripts/test-windows-window-state.ps1
```

スクリプトは専用のGhosttyプロセスを1つ起動し、既存のGhosttyウィンドウには
触れません。スナップに必要なウィンドウスタイル、Alt+Tabとタスクバーの対象に
なれるトップレベル構造、ウィンドウクラスの大・小アイコン、DWMの表示状態を
確認します。さらに、最小化から直前の最大化状態へ戻ること、通常状態へ復元した
位置とサイズ、`WM_CLOSE` 後の終了コードを検査します。専用 `cmd.exe` 端末へ
文字列とEnterを送り、一時マーカーの
内容からコマンド実行を確認します。またリポジトリ内の一時設定を使い、設定再読込
によってタブバーが表示、非表示、再表示へ切り替わることを確認します。その後
テスト用の右分割を作成し、タブバーと分割境界が各モニター、最大化、復元へ追従
することも確認します。最後に2つ目のトップレベルウィンドウを作成し、両
ウィンドウへの設定再読込同期、フォーカス移動と巡回、一括非表示と復帰を確認
します。個別終了で元ウィンドウが残ること、再作成後の一括終了でプロセスが正常
終了することも検査します。利用者の設定ファイルは変更せず、一時設定とマーカーは
正常終了後または自動後処理後に削除します。標準出力と標準エラーは
`zig-out/logs` に保存されます。別の実行ファイルを確認する場合は次のように
指定します。

```powershell
./scripts/test-windows-window-state.ps1 `
    -Executable zig-out/version-check-script/bin/ghostty.exe
```

D3D11、DirectComposition、シェーダー、スワップチェーン、画像資源の再作成と、
同じ端末セッションで復旧後もコマンドを実行できることは、専用テストフックで
確認できます。このオプションは物理的なGPU障害を発生させません。

```powershell
./scripts/test-windows-window-state.ps1 -TestGpuRecovery
```

同じプロセスで連続再作成を検査する場合は回数を指定します。

```powershell
./scripts/test-windows-window-state.ps1 `
    -TestGpuRecovery `
    -GpuRecoveryIterations 20
```

一時的な再初期化失敗への有限再試行は、最初の2回を制御失敗させて確認できます。
再試行は最大3回で、待機時間は100ms、250msです。

```powershell
./scripts/test-windows-window-state.ps1 `
    -TestGpuRecovery `
    -GpuRecoveryFailures 2
```

2026年9月15日にRelease版の同一端末セッションで20回連続実行し、再作成の
開始20回、完了20回、失敗0、既知のログ異常0を確認しました。その後の端末入力、
設定再読込、分割、4モニター移動、複数ウィンドウ操作、正常終了も成功しています。
制御失敗2回の試験では3回目に復旧し、端末セッションと全GUI回帰を維持しました。
制御失敗3回の負側試験では、再試行待機2回、最終失敗1回、4回目の試行0となり、
無限再試行しないことも確認しています。

Windowsのサスペンド・自動復帰通知を専用プロセスへ送り、電源復帰時のGPU資源
再作成と端末セッション維持を確認する場合は次を実行します。この試験はPC自体を
スリープさせません。

```powershell
./scripts/test-windows-window-state.ps1 -TestPowerResume
```

2026年9月15日にRelease版で、まず単一サーフェスを復旧し、次に分割済みの
ウィンドウと別ウィンドウに属する全3サーフェスを同時に復旧しました。2つ目の
トップレベルウィンドウへ届く重複復帰通知は抑止され、合計でサスペンド検出2回、
復帰検出2回、GPU再作成の開始・完了各4回、失敗0でした。復旧後の端末入力と
全GUI回帰も成功しました。

スナップ、Alt+Tab、タスクバーについて、このスクリプトが確認するのはWindows
シェルの対象となるための構造です。実際のキー操作、スナップレイアウト、タスク
バーからの操作は別途実機で確認します。

接続中の各モニターへ専用ウィンドウを順番に移動し、親クライアント領域と
`GhosttyTabBar` の原点、幅、DPI、DPI別の高さ、所有関係も検査します。試験後は
ウィンドウを初期位置へ戻します。異なるDPIのモニターが接続されていない場合、
混在DPIの確認にはならないため、出力されたモニター別DPIを確認してください。

## 反復・長時間回帰確認

ウィンドウ状態の回帰試験を20回繰り返す場合は次を実行します。

```powershell
./scripts/test-windows-soak.ps1 -Iterations 20
```

GPU資源の制御再作成と、PCをスリープさせない電源復帰通知試験を各反復に含める
場合は次を実行します。

```powershell
./scripts/test-windows-soak.ps1 `
    -Iterations 20 `
    -DelaySeconds 0 `
    -TestGpuRecovery `
    -GpuRecoveryIterations 1 `
    -TestPowerResume
```

時間を基準に実行する場合は分単位で指定します。この場合、反復回数の指定は
使用されません。開始済みの回帰試験は途中で打ち切らず、完了後に終了時刻を
判定します。

```powershell
./scripts/test-windows-soak.ps1 -DurationMinutes 60
```

各回は独立したGhosttyプロセスを使用します。起動、文字入力、設定再読込、
分割とDPI追従、複数ウィンドウ、正常終了を反復し、試験結果と個別ログのパスを
`zig-out/logs/windows-soak-*.json` へ毎回保存します。失敗時も、それまでの結果と
エラーをJSONへ残して終了します。この試験はプロセスの反復起動と終了を対象とし、
1つの端末セッションを開いたままにする連続稼働試験ではありません。

2026年9月15日にRelease版で20反復の基準試験を実行し、20回すべて成功、失敗0、
強制終了0、ログ異常0、一時ファイル残留0を確認しました。所要時間は40.054秒です。
数時間規模の試験は別途必要です。

同日にGPU再作成と制御電源復帰を含む20反復も実行し、20個の独立プロセスが
59.004秒ですべて成功しました。各プロセス5回、合計100回のGPU資源再作成が
すべて完了し、復旧失敗0、不正なJSON記録0、一時ファイル残留0でした。

## Windowsシェルの手動受け入れ確認

自動回帰試験は、スナップ、Alt+Tab、タスクバーの対象となるためのウィンドウ
構造を検査します。Windowsシェル上の見た目と実操作は、次の手動試験で記録します。
項目だけを確認する場合はGhosttyを起動しません。

```powershell
./scripts/test-windows-shell.ps1 -ListOnly
```

受け入れ試験を開始する場合は次を実行します。

```powershell
./scripts/test-windows-shell.ps1
```

特定項目だけを再確認する場合は、項目IDを指定できます。

```powershell
./scripts/test-windows-shell.ps1 -CheckId alt-tab
```

スクリプトは利用者設定に触れず、専用のGhosttyプロセスと一時設定を使用します。
次の6項目について `p`（合格）、`f`（不合格）、`s`（スキップ）、`q`（中止）を
入力します。

1. Alt+Tabでの表示とフォーカス
2. タスクバーボタンによる最小化・復元・フォーカス
3. `Win+Left` と `Win+Right` によるスナップ
4. `Win+Z` または最大化ボタンからのスナップレイアウト
5. 2ウィンドウのAlt+Tabとタスクバーの個別選択
6. タスクバープレビューからの個別終了と全終了

実機スリープ復帰は通常の6項目には含まれません。ほかの作業を保存してから、
次のように明示的に選択します。

```powershell
./scripts/test-windows-shell.ps1 -CheckId power-resume
```

復帰後に同じ端末の内容と入力、描画状態を目視確認します。最終JSONには手動回答に
加えて、診断ログから取得したサスペンド通知数、復帰通知数、予定されたレンダラー
復旧数、完了数、失敗数を保存します。手動で合格を選んでも、ログ上の自動検証が
不合格の場合は全体合格になりません。

回答ごとに `zig-out/logs/windows-shell-*.json` を更新します。中止や失敗でも、
回答済み項目、実行環境、実行ファイルの版とSHA-256、診断ログ、エラーを保存します。
試験終了時は専用プロセスと一時設定を後処理します。

2026年9月15日のWindows 11実操作では、タスクバー操作、左右スナップ、スナップ
レイアウト、2ウィンドウの選択、タスクバーからの個別・全終了が合格しました。
最初の試験ではAlt+Tabのアイコンが固有のものではありませんでしたが、大・小の
Ghosttyアイコンをウィンドウクラスへ設定した修正版で再試験し、合格しました。
修正版ではクラスアイコンを検査する自動回帰も20反復し、すべて成功しています。

## Windows GUI設定

設定例:

```text
window-show-tab-bar = auto
window-new-tab-position = current
window-theme = ghostty
window-titlebar-background = 1E1E1E
window-titlebar-foreground = F0F0F0
background-opacity = 0.90
background-blur = false
```

主な設定:

- `window-show-tab-bar`: `auto`、`always`、`never`。`auto` は複数タブまたは
  分割ズーム中に表示します。
- `window-new-tab-position`: `current` は現在のタブの直後、`end` は末尾へ
  新規タブを追加します。
- `window-theme`: `auto`、`system`、`dark`、`light`、`ghostty`。
  `ghostty` の場合はタイトルバーへ設定色を反映します。
- `background-opacity`: D3D11版では背景透過へ反映します。
- `background-blur`: Windowsでは表示品質が環境依存です。現段階では
  `false` を推奨します。

Windowsのハイコントラストが有効な場合は、タブバーと分割境界へシステム色を
使用し、タイトルバーの任意色を解除してWindows管理の配色へ戻します。

## 既定のタブ操作

| キーまたは操作 | 動作 |
|---|---|
| `Ctrl+Shift+T` | 新しいタブ |
| `Ctrl+Shift+W` | 現在のタブを閉じる |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | 次／前のタブ |
| `Ctrl+PageDown` / `Ctrl+PageUp` | 次／前のタブ |
| `Alt+1`〜`Alt+8` | 指定番号のタブ |
| `Alt+9` | 最後のタブ |
| `Ctrl+Shift+PageDown` / `Ctrl+Shift+PageUp` | タブを右／左へ移動 |
| タブをクリック | タブを選択 |
| タブをドラッグ | タブを並べ替え |
| タブをダブルクリック | 任意のタブ名を設定。空欄で端末タイトルへ戻す |
| タブの `×` | タブを閉じる |
| タブバーの `+` | 新しいタブ |
| タブバー上のホイール | 次／前のタブ |

## 既定の分割操作

| キーまたは操作 | 動作 |
|---|---|
| `Ctrl+Shift+O` | 右に分割 |
| `Ctrl+Shift+E` | 下に分割 |
| `Ctrl+Alt+矢印` | 指定方向のペインへ移動 |
| `Ctrl+Win+[` / `Ctrl+Win+]` | 前／次のペインへ移動 |
| `Ctrl+Win+Shift+矢印` | ペインを指定方向へリサイズ |
| `Ctrl+Shift+Enter` | 現在のペインのズーム切り替え |
| 分割境界をドラッグ | ペインをリサイズ |

そのほか、`Ctrl+Shift+N` は新しいウィンドウ、`Ctrl+Enter` は全画面切り替え、
`Alt+F4` はウィンドウを閉じ、`Ctrl+Shift+Q` はGhosttyを終了します。

## アクセシビリティ

カスタム描画のタブバーは、MSAAのページタブ一覧として公開されます。各タブの
名前、位置、選択状態、前後移動、ヒットテスト、既定操作を取得できます。

APIレベルの検査と自動回帰テストは完了していますが、NarratorおよびNVDAでの
音声読み上げはまだ受け入れ確認中です。

## 既知の制限

- Windows 11では基本動作を確認していますが、Windows 10は未確認です。
- 96 DPIと120 DPIのモニター間移動は実機で自動確認済みですが、144 DPIと
  192 DPIの実機確認は完了していません。
- 最大化と最小化からの復元、20反復の耐久基準試験は自動確認済みです。
  GPU資源の制御再作成と端末セッション維持は自動確認済みですが、実際のGPU
  デバイスロストまたはドライバー障害からの復旧と、PCを実際にスリープさせた
  復帰試験、数時間規模の連続試験は未確認です。Windowsのサスペンド・復帰通知を
  使った制御復帰試験は確認済みです。D3D11の提示HRESULTとデバイス削除理由は
  診断ログへ記録されます。
- `background-blur` はWindowsやGPUの構成によって効果と品質が変わります。
- Windows版のインストーラー、署名、自動更新はまだ提供していません。
- macOS版のSwiftUI設定画面やLinux版のGTK統合と同等のGUIはありません。

実装状況と検証項目の詳細は
[Windows実用化ロードマップ](windows-roadmap.md)を参照してください。
