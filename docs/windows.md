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
サブシステム、CLIとWindowsの版情報、シェル統合、テーマ、ファイルサイズ、
SHA-256を検証して表示します。

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

Release実行ファイルの混在DPIモニター追従、分割境界、最大化、最小化、復元、
正常終了をまとめて確認できます。

```powershell
./scripts/test-windows-window-state.ps1
```

スクリプトは専用のGhosttyプロセスを1つ起動し、既存のGhosttyウィンドウには
触れません。スナップに必要なウィンドウスタイル、Alt+Tabとタスクバーの対象に
なれるトップレベル構造、DWMの表示状態を確認します。さらに、最小化から直前の
最大化状態へ戻ること、通常状態へ復元した位置とサイズ、`WM_CLOSE` 後の終了
コードを検査します。テスト用の右分割を作成し、タブバーと分割境界が各モニター、
最大化、復元へ追従することも確認してからプロセスを閉じます。標準出力と標準
エラーは `zig-out/logs` に保存されます。別の実行ファイルを確認する場合は次の
ように指定します。

```powershell
./scripts/test-windows-window-state.ps1 `
    -Executable zig-out/version-check-script/bin/ghostty.exe
```

スナップ、Alt+Tab、タスクバーについて、このスクリプトが確認するのはWindows
シェルの対象となるための構造です。実際のキー操作、スナップレイアウト、タスク
バーからの操作は別途実機で確認します。

接続中の各モニターへ専用ウィンドウを順番に移動し、親クライアント領域と
`GhosttyTabBar` の原点、幅、DPI、DPI別の高さ、所有関係も検査します。試験後は
ウィンドウを初期位置へ戻します。異なるDPIのモニターが接続されていない場合、
混在DPIの確認にはならないため、出力されたモニター別DPIを確認してください。

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
- 最大化と最小化からの復元は自動確認済みです。スリープ復帰、GPUデバイス
  ロスト、長時間稼働の回帰試験が残っています。
- `background-blur` はWindowsやGPUの構成によって効果と品質が変わります。
- Windows版のインストーラー、署名、自動更新はまだ提供していません。
- macOS版のSwiftUI設定画面やLinux版のGTK統合と同等のGUIはありません。

実装状況と検証項目の詳細は
[Windows実用化ロードマップ](windows-roadmap.md)を参照してください。
