<!-- LOGO -->
<h1>
<p align="center">
  <img src="dist/windows/ghoultty-icon-candidate.png" alt="Logo" width="128">
  <br>Gooztty
</h1>
  <p align="center">
    Ghostty をもとにした Windows ネイティブの端末 — 開発中のフォーク。
    <br />
    Win32、D3D11、DirectComposition、ネイティブのタブと分割ペイン。
    <br />
    <a href="#gooztty">概要</a>
    ·
    <a href="docs/windows.md">ユーザーガイド</a>
    ·
    <a href="#ghostty-for-windows-からの移行">Ghostty からの移行</a>
    ·
    <a href="#設定の対応状況">設定</a>
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

## Gooztty

Gooztty は、[Ghostty](https://github.com/ghostty-org/ghostty) から作った
Windows ネイティブの端末アプリケーションです。Ghostty を日常的に使えるように
Windows へ移植するフォークとして始まり、Ghostty プロジェクトの求めに応じて
独自の名前を付けました。端末そのものは Ghostty のものです。

`1.3.2-windows.16` までのリリースは、Ghostty の名前で公開しました。
Gooztty の名前での版はまだ公開していません。名前の変更は `gooztty` ブランチで
進めています。

主な特長:

- Win32 のネイティブウィンドウ、タイトルバー、タブバー
- D3D11 と DirectComposition による描画、背景の透過、GPU デバイスの喪失や
  スリープ復帰からの自動回復
- 複数ウィンドウ、ネイティブのタブ、入れ子の分割ペイン
- キーボードとマウスによるタブの管理・並べ替え、分割の仕切り線でのサイズ変更
- Windows の IME、クリップボード、URL とファイルの扱い
- Per-Monitor V2 DPI、ハイコントラスト、MSAA によるタブ情報
- `%LOCALAPPDATA%\gooztty\config.gooztty` の読み込みと再読み込み
- ポータブルなリリースビルド用スクリプトと、コード署名に対応した
  Inno Setup のインストーラー用スクリプト
- CLI と Windows のファイルプロパティで共通のビルドバージョン情報

ビルドと実行:

```powershell
zig build
./zig-out/bin/gooztty.exe
```

ポータブルなリリースビルド:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/gooztty.exe
```

プレビュー版の内容と検証結果は[リリースノート](docs/windows-release-notes.md)、
版ごとの変更は[変更履歴](docs/windows-changelog.md)を参照してください。

ビルドやインストール済みのバージョンの確認(`gooztty.exe` は GUI
アプリケーションなので、出力をパイプで渡して PowerShell に完了を待たせて表示します):

```powershell
./zig-out/release/bin/gooztty.exe --version | Out-String
# 現在のユーザーにインストールした場合
& "$env:LOCALAPPDATA\Programs\Gooztty\bin\gooztty.exe" --version | Out-String
# 同じバージョンがファイルのプロパティにもある
(Get-Item ./zig-out/release/bin/gooztty.exe).VersionInfo.ProductVersion
```

リリースビルドとインストーラーは `dist/windows/version.txt` からバージョンを取り、
インストーラーのスクリプトは異なるバージョンを報告するリリース実行ファイルを
受け付けません(`-Sign` は実行ファイル、インストーラー、アンインストーラーに
署名します):

```powershell
./scripts/build-installer.ps1
./scripts/build-installer.ps1 -Sign   # 証明書のサブジェクトは $env:CODESIGN_CERT
```

ポータブル版の ZIP も、同じリリースビルドから作り、同じように確認します(`-Sign` は
ZIP に入れる実行ファイルに署名します):

```powershell
./scripts/build-zip.ps1 -Sign   # zig-out\zip\gooztty-<版>-x64-portable.zip
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

Gooztty はプレビュー版です。Windows 11 で、144/192 DPI、ハイコントラスト、
ナレーター、実機でのスリープと復帰、日本語とドイツ語のキーボード配列を含めて
確認しています。Windows 10 はサポート対象外です。数時間にわたる連続使用と、
実際の GPU デバイスの喪失はまだ確認していません。`1.3.2-windows.4` から、
署名付きのインストーラーをリリースのアセットとして公開しています。自動更新は
ありません。背景の透過は動作しますが、`background-blur` の品質は環境によって
異なるため、当面は無効にしておくことを勧めます。

### 作業フェーズ

現在の計画は、残りの Windows 対応から、Ghostty の名前からの名称変更
([#31](https://github.com/fukuyori/ghostty/issues/31))までです。それ以前の
開発フェーズは[ロードマップ](docs/windows-roadmap.md#5-overall-progress)に
記録しています。

| ステップ | 作業 | ブランチ | 状態 |
|---:|---|---|---|
| 1 | IME の一部確定で文字が重なる問題の修正(#48) | `windows` | 完了 |
| 2 | タスクバーの進捗表示(F4、#33) | `windows` | 完了 |
| 3 | HTML クリップボード(F5、#34) | `windows` | 完了 |
| 4 | セッションの保存と復元(F6、#35) | `windows` | 完了 |
| 5 | Quick terminal と global キーバインド(F7、#24) | `windows` | 完了 |
| 6 | デスクトップ通知とコマンド終了通知(F8、#21) | `windows` | 完了 |
| 7 | Ghostty の名前でのリリース | `windows` | 完了(`1.3.2-windows.16`) |
| 8 | 値を変えずに名前を切り替える仕組みの整備、upstream との同期、`gooztty` の作成 | `windows` → `gooztty` | 完了 |
| 9 | Gooztty の名前の適用: ビルドと UI、設定と端末の識別子、インストーラー、文書 | `gooztty` | 完了 |
| 10 | 名前を変えたアプリの受け入れ: 名前、パス、通知の識別子、署名付きインストーラー、インストールと削除 | `gooztty` | 完了 |

残っている実機での検証、未決定の事項、先送りしたリファクタリングは
[issue](https://github.com/fukuyori/ghostty/issues) で管理しています。

設定、既定のキーバインド、診断、既知の制限は[ユーザーガイド](docs/windows.md)に、
実装済みの項目と残りの作業は[ロードマップ](docs/windows-roadmap.md)にあります。

## Ghostty for Windows からの移行

Gooztty は、Ghostty for Windows のプレビュー版(`1.3.2-windows.16` 以前)の
アップグレードではなく、別のアプリケーションとしてインストールされます。
両方を同時にインストールしておけます。自動では何も引き継ぎません。

- **設定。** Gooztty は `%LOCALAPPDATA%\gooztty\config.gooztty`
  (または `%XDG_CONFIG_HOME%\gooztty\config.gooztty`)を読み、古い
  `%LOCALAPPDATA%\ghostty` は読みません。設定はご自身でコピーしてください。
  たとえば `ghostty\config.ghostty` を `gooztty\config.gooztty` にコピーします。
  独自のテーマは `ghostty\themes` から `gooztty\themes` に移します。Gooztty の
  インストールとアンインストールは、古いディレクトリに触れません。
- **コマンド。** コマンドは `gooztty` です。`ghostty.exe` の別名は用意しません。
  `ghostty` は、古いアプリケーションを削除するまで、古い方を起動します。
- **端末の種類。** Gooztty は `TERM=xterm-gooztty`、`TERM_PROGRAM=gooztty`、
  `GOOZTTY_*` の環境変数を設定します。terminfo のエントリは、古い
  `xterm-ghostty` の隣に登録し、古い方はそのまま残します。WSL、Cygwin、MSYS2、
  リモートのホストでは、[ユーザーガイド](docs/windows.md#terminal-type-and-terminfo)
  の手順で、新しいエントリを一度インストールしてください。
- **ご自身で設定した環境変数。** `GHOSTTY_LOG` などは `GOOZTTY_LOG` のように
  名前を変えてください。
- **古いアプリケーションの削除。** Ghostty は「アプリと機能」からアンインストール
  してください。ファイル、ショートカット、`PATH` の登録は、Ghostty 自身の
  アンインストーラーが削除します。`%LOCALAPPDATA%\ghostty` は、古い設定が
  不要になったらご自身で削除してください。

## 設定の対応状況

Gooztty は upstream の Ghostty と同じ形式の設定ファイルを
`%LOCALAPPDATA%\gooztty\config.gooztty` から読みますが、すべての設定項目が
Windows で効くわけではありません。`1.3.2-windows.16` 時点で、upstream の
全 212 項目のうち Windows で使えるのは 136 項目(64%、◎ と ○)です。
一部だけ使えるものを含めると 144 項目(68%)です。

| 状態 | 項目数 | 意味 |
|---|---:|---|
| ◎ | 41 | Windows で使える。動作確認の記録がある |
| ○ | 95 | Windows で使える(コードから判断) |
| △ | 8 | 一部だけ使える |
| ✕ | 24 | Windows では未実装 |
| - | 44 | 対象外。macOS、GTK、Linux、X11、Wayland だけの設定 |

主な未対応の点:

- 未実装: フォーカスのない分割ペインを暗くする設定と `split-divider-color`、
  ウィンドウの初期位置、`window-inherit-font-size`、サイズ変更時のサイズ表示、
  `focus-follows-mouse`、`undo-timeout`、リンクのプレビュー、カスタムシェーダー
  ([#14](https://github.com/fukuyori/ghostty/issues/14))、音声のベル。
- 一部だけ: `light:`/`dark:` のテーマの組み合わせは常にライト側になる、
  `mouse-scroll-multiplier` は `discrete` の値だけ効く、`copy-on-select = primary`
  と中クリックの貼り付けに使う選択範囲用のクリップボードがない、PowerShell の
  自動統合は作業ディレクトリだけを通知する、`bell-features` は `system`、
  `attention`、`title` に対応。
- 対象外(44 項目): macOS 専用の 22 項目(`macos-*`、自動更新、CoreText の
  フォントの太さ調整、Spaces での Quick terminal の動作)、GTK・X11・Wayland
  専用の 17 項目(`gtk-*`、`class`、`window-subtitle`、アプリ内通知、UI の
  言語など)、Linux 専用の 5 項目(`linux-cgroup*`、`async-backend`)。

全項目の状態と内容は
[Windows での設定の対応状況](docs/windows-config-support.ja.md)を参照してください。

## クラッシュレポートと診断

Ghostty の Sentry によるクラッシュレポートは、Gooztty では使えません。
macOS 以外のすべてのプラットフォームで既定で無効になっており
(`src/build/Config.zig`)、`-Dsentry=true` でビルドしても Windows では
レポーターがすぐに戻ります(`src/crash/sentry.zig`)。クラッシュ用の
ディレクトリは作られず、`gooztty +crash-report` も何も表示しません。

代わりに起動時の診断ログを使ってください。実行ファイルは GUI サブシステムの
バイナリなので、標準出力と標準エラーは起動したコンソールにつながりません。
次のスクリプトは両方をファイルに書き出し、終了コードを報告します。

```powershell
.\scripts\run-windows-diagnostics.ps1
.\scripts\run-windows-diagnostics.ps1 -AdditionalArguments @('+validate-config') -Wait
```

ログは `zig-out\logs` に保存されます。自分で起動したセッションを記録するには、
`GOOZTTY_LOG=stderr=true` を設定して標準エラーをリダイレクトします。D3D11 の
表示の失敗、デバイスが削除された理由、GPU リソースの回復、スリープと復帰の
通知は、すべてそこに記録されます。

## upstream との関係

Gooztty は、Ghostty 本体と macOS・Linux のアプリケーションを管理している
[`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) のフォークです。
端末のエミュレーション、設定、コードの大部分は Ghostty のもので、このリポジトリは
Windows アプリケーションを加えています。upstream の変更は、Windows への移植を
upstream に合わせて保つ `windows` ブランチを通じて随時取り込み、Gooztty は
`gooztty` ブランチで開発しています。

Windows に固有でないことは、upstream の資料を参照してください:

- [About Ghostty](https://ghostty.org/docs/about)
- [Documentation](https://ghostty.org/docs)(設定のリファレンスとキーバインドを含み、
  Gooztty にも当てはまります)
- macOS と Linux 版の [Downloads](https://ghostty.org/download)
- upstream の開発については
  [Contributing](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md)
  と [Developing](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md)

Gooztty に固有のことは、upstream ではなく、このリポジトリの issue で報告して
ください。

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
> にあります。このフォークの issue には適用されません。このフォークは
> プルリクエストを受け付けていません。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。upstream の著作権表示を保持しています。
