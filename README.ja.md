<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty
</h1>
  <p align="center">
    Windows 向けネイティブ Ghostty — 開発中の Windows アプリケーションのフォーク。
    <br />
    Win32、D3D11、DirectComposition、ネイティブのタブと分割ペイン。
    <br />
    <a href="#ghostty-for-windows">Windows ビルド</a>
    ·
    <a href="docs/windows.md">ユーザーガイド</a>
    ·
    <a href="docs/windows-release-notes.md">リリースノート</a>
    ·
    <a href="docs/windows-changelog.md">変更履歴</a>
    ·
    <a href="docs/windows-roadmap.md">ロードマップ</a>
    ·
    <a href="#upstream-との関係">Upstream</a>
    ·
    <a href="README.md">English</a>
  </p>
</p>

この文書は [README.md](README.md) の日本語版です。リンク先の文書は、設定対応表を除き英語です。

## Ghostty for Windows

このリポジトリは、Ghostty を日常的に使えるネイティブアプリケーションとして
Windows で動かすための開発用フォークです。upstream が Windows に対応するのを
待たずに、ネイティブ実装とその検証を `windows` ブランチで進めています。

Windows ビルドの主な特長:

- Win32 のネイティブウィンドウ、タイトルバー、タブバー
- D3D11 と DirectComposition による描画、背景の透過、GPU デバイスの喪失や
  スリープ復帰からの自動回復
- 複数ウィンドウ、ネイティブのタブ、入れ子の分割ペイン
- キーボードとマウスによるタブの管理・並べ替え、分割の仕切り線でのサイズ変更
- Windows の IME、クリップボード、URL とファイルの扱い
- Per-Monitor V2 DPI、ハイコントラスト、MSAA によるタブ情報
- `%LOCALAPPDATA%\ghostty\config.ghostty` の読み込みと再読み込み
- ポータブルなリリースビルド用スクリプトと、コード署名に対応した
  Inno Setup のインストーラー用スクリプト
- CLI と Windows のファイルプロパティで共通のビルドバージョン情報

ビルドと実行:

```powershell
zig build
./zig-out/bin/ghostty.exe
```

ポータブルなリリースビルド:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/ghostty.exe
```

プレビュー版の内容と検証結果は [Windows リリースノート](docs/windows-release-notes.md)、
版ごとの変更は[変更履歴](docs/windows-changelog.md)を参照してください。
[Windows での設定の対応状況](docs/windows-config-support.ja.md)には、
未実装のものを含む全設定項目の Windows での対応状況をまとめています。

ビルドやインストール済みのバージョンの確認(`ghostty.exe` は GUI
アプリケーションなので、出力をパイプで渡して PowerShell に完了を待たせて表示します):

```powershell
./zig-out/release/bin/ghostty.exe --version | Out-String
# 現在のユーザーにインストールした場合
& "$env:LOCALAPPDATA\Programs\Ghostty\bin\ghostty.exe" --version | Out-String
# 同じバージョンがファイルのプロパティにもある
(Get-Item ./zig-out/release/bin/ghostty.exe).VersionInfo.ProductVersion
```

リリースビルドとインストーラーは `dist/windows/version.txt` からバージョンを取り、
インストーラーのスクリプトは異なるバージョンを報告するリリース実行ファイルを
受け付けません(`-Sign` は実行ファイル、インストーラー、アンインストーラーに
署名します):

```powershell
./scripts/build-installer.ps1
./scripts/build-installer.ps1 -Sign   # 証明書のサブジェクトは $env:CODESIGN_CERT
```

リリースビルドに対する繰り返しの回帰テスト:

```powershell
./scripts/test-windows-soak.ps1 -Iterations 20
# 制御した GPU リソースの回復とスリープ復帰を含める
./scripts/test-windows-soak.ps1 -Iterations 20 -DelaySeconds 0 `
    -TestGpuRecovery -TestPowerResume
```

Windows シェルの手動受け入れチェック:

```powershell
./scripts/test-windows-shell.ps1 -ListOnly
./scripts/test-windows-shell.ps1
# 実際のスリープと復帰は明示的に選んだときだけ行う
./scripts/test-windows-shell.ps1 -CheckId power-resume
```

Windows ビルドはプレビュー版です。Windows 11 で、144/192 DPI、ハイコントラスト、
ナレーター、実機でのスリープと復帰、日本語とドイツ語のキーボード配列を含めて
確認しています。Windows 10 はサポート対象外です。数時間にわたる連続使用と、
実際の GPU デバイスの喪失はまだ確認していません。`1.3.2-windows.4` から、
署名付きのインストーラーをリリースのアセットとして公開しています。自動更新は
ありません。背景の透過は動作しますが、`background-blur` の品質は環境によって
異なるため、当面は無効にしておくことを勧めます。

### 作業フェーズ

Windows 対応は 7 つのフェーズで進め、すべて完了しています。

| フェーズ | 範囲 | 状態 |
|---|---|---:|
| 1 | 基本ランタイム: 起動、入力、IME、クリップボード、DPI | 完了 |
| 2 | 描画: D3D11、DirectComposition、背景の透過、画像 | 完了 |
| 3 | ウィンドウ機能: 複数ウィンドウ、全画面、設定の再読み込み | 完了 |
| 4 | 分割ペイン: 作成、移動、サイズ変更、ズーム | 完了 |
| 5 | Windows GUI の仕上げ: タブ、マウス操作、DPI、アクセシビリティ | 完了 |
| 6 | リリース品質: 診断、リリース検証、実機テスト、配布 | 完了 |
| 7 | upstream の機能: コマンドパレット、スクロールバー、ファイルのドロップ、タスクバーの進捗、HTML クリップボード、セッションの復元、Quick terminal、通知 | 完了 |

フェーズ 7 は `1.3.2-windows.16` でリリースしました。次は Ghostty の名前からの
名称変更([#31](https://github.com/fukuyori/ghostty/issues/31))で、`windows` で
名前を切り替える仕組みを整えた後、別の `gooztty` ブランチで進めます。

残っている実機での検証、未決定の事項、先送りしたリファクタリングは
[issue](https://github.com/fukuyori/ghostty/issues) で管理しています。

設定、既定のキーバインド、診断、既知の制限は
[Windows ユーザーガイド](docs/windows.md)に、実装済みの項目と残りの作業は
[Windows ロードマップ](docs/windows-roadmap.md)にあります。

## クラッシュレポートと診断

Ghostty の Sentry によるクラッシュレポートは、Windows ビルドでは使えません。
macOS 以外のすべてのプラットフォームで既定で無効になっており
(`src/build/Config.zig`)、`-Dsentry=true` でビルドしても Windows では
レポーターがすぐに戻ります(`src/crash/sentry.zig`)。クラッシュ用の
ディレクトリは作られず、`ghostty +crash-report` も何も表示しません。

代わりに起動時の診断ログを使ってください。実行ファイルは GUI サブシステムの
バイナリなので、標準出力と標準エラーは起動したコンソールにつながりません。
次のスクリプトは両方をファイルに書き出し、終了コードを報告します。

```powershell
.\scripts\run-windows-diagnostics.ps1
.\scripts\run-windows-diagnostics.ps1 -AdditionalArguments @('+validate-config') -Wait
```

ログは `zig-out\logs` に保存されます。自分で起動したセッションを記録するには、
`GHOSTTY_LOG=stderr=true` を設定して標準エラーをリダイレクトします。D3D11 の
表示の失敗、デバイスが削除された理由、GPU リソースの回復、スリープと復帰の
通知は、すべてそこに記録されます。

## upstream との関係

このリポジトリは、Ghostty 本体と macOS・Linux のアプリケーションを管理している
[`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) のフォークです。
ここでは Windows アプリケーションだけを `windows` ブランチで開発しており、
upstream の変更は随時取り込んでいます。

Windows に固有でないことは、upstream の資料を参照してください:

- [About Ghostty](https://ghostty.org/docs/about)
- [Documentation](https://ghostty.org/docs)(設定のリファレンスとキーバインドを含み、
  このビルドにも当てはまります)
- macOS と Linux 版の [Downloads](https://ghostty.org/download)
- upstream の開発については
  [Contributing](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md)
  と [Developing](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md)

Windows ビルドに固有のことは、このリポジトリの issue で報告してください。

> [!IMPORTANT]
>
> **upstream には厳格な貢献の手順があり、このフォークはそれに参加していません。**
>
> - **推薦(vouch)が必要です。** 初めての貢献者は推薦依頼のディスカッションを
>   開き、メンテナーの承認を受ける必要があります。推薦されていない貢献者の
>   プルリクエストは自動的に閉じられます。
> - **自分のコードを理解している必要があります。** AI ツールの助けなしに、変更内容と
>   それがシステムのほかの部分とどう関わるかを説明できない場合は、貢献しないよう
>   求められています。
> - **AI の利用はすべて開示する必要があります。** ツール名と支援の範囲を明記します。
>   [AI Usage Policy](https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md)
>   を参照してください。
> - **規則違反の繰り返しや質の低い作業は告発(denouncement)につながり**、
>   公開で記録されます。
>
> このフォークは AI の支援を受けて開発しているため、**ここから upstream に issue や
> プルリクエストを出すことはありません。** すべてこのリポジトリ内で扱います。
> upstream に何かを伝えたい場合は、上記の規則に従い、ご自身のアカウントで
> 行ってください。
>
> 全文は
> [CONTRIBUTING.md](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md)
> にあります。このフォークの issue とプルリクエストには、いずれも適用されません。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。upstream の著作権表示を保持しています。
