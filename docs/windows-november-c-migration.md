# N16: 固定Cへの統合（2026-10-31）

固定Cの競合解消・両製品の段階検証とマージを完了。既知失敗と追加で確認したBからのpipe出力不具合は下記のとおり残る。

- Windows基準: `cbf203f9e`、Gooztty基準: `f5f4e7474`。
- 固定B: `83fb95624b0439ee660c2679b43b38c8b63769cd`。
- 固定C/main: `fbed180a5f181915c92a8f2f561903a6e4645b5a`（Bから67コミット、1.4.1-dev）。
- Zig 0.17.0、プロセス内のpkgを`zig-out/n03-clean-pkg-c`に指定。z2d 0.13.2とzigimgの固定hash/cacheはN03台帳と一致。
- Windowsは`06d12a298958ee97ee3d46b0c7f16658eeca8a21`、Goozttyは`281c300aee9cbc42f7a5ff08ab62561a113aa3b9`としてマージ。

## 競合解消

削除済み`.github/VOUCHED.td`と上流test.ymlは削除を維持。
`src/input/command.zig`はWindowsのbrand.display_nameを保持し、他OSのGhosttyタイトルは上流どおり翻訳対象から外した。説明文のWindowsブランド切り替えは保持。fmtとdiff-check成功、未解消競合なし。

## 検証と重点項目

`zig-out/n16-run.ps1`と`n16-gooztty-run.ps1`でDebug/fast/hook、全Zig、Win32通常/hook、GUI/parity、設定診断、制御GPU/電源復帰、lifecycleを記録。GoozttyのGUIはWindowsドライバー完了後に開始し、同時操作を避ける。

- Windows台帳: `.worktrees/windows-nov/zig-out/logs/n16-c-20261031-184237-939/summary.json`。
- Gooztty台帳: `.worktrees/n16-gooztty/zig-out/logs/n16-c-20261031-184309-690/summary.json`。
- 上流追加テスト35件の一覧: `zig-out/n16-upstream-added-tests.txt`。Unicode、UTF-8、長いenv、空コマンド/空白、ゼロ容量循環バッファ、DECIC/DECDC/DECBI/DECFI、右端pending wrap、tmux通知/所有権を対象とする。Windowsで引用符外のエスケープ試験は既定のskip条件があり、追加件数だけで実行数を断定しない。

### SSH認証メッセージ

`zig-out/n16-ssh-probe.c`はssh -G、terminfo用stdin受信、認証案内のstderr出力、最終sessionのTERM記録を模擬する。ネットワーク接続は行わない。
両製品でverbose有無×install成功/失敗の4条件、計8条件が成功。認証案内は通常時も届き、remote scriptのstderr抑制は非verboseのみ。成功時はブランドterminfo、失敗時はxterm-256colorへfallbackし、後続sessionはexit 0。
`zig-out/n16-ssh-windows-results.json`、`n16-ssh-gooztty-results.json`に保存。統合時点では実サーバーの認証を未確認だった。
初回はPowerShellからGUI exeを直接呼ぶ検証器が終了待ち/標準ハンドルを正しく扱えず、argsログ作成前に読み出して失敗。ProcessStartInfoで明示的にpipeを設定し、終了を待つよう検証器を修正。初回のログも保持し、製品修正とは扱わない。

2026-10-31追試では、`fuk@192.168.12.12:22`へのWindows OpenSSH接続が公開鍵認証で成功し、`exit`の終了コードは0。N16 Gooztty Debugビルド（SHA-256 `BA9C958C687742ABF6ECE4B52EC72ABE3C736AE06C2D342B964E0C5F7FDBF348`）から `+ssh --terminfo=false --forward-env=false ... exit 37` を実行し、終了コード37が返ることを確認した。既知ホストはリポジトリ内の一時known_hostsで検証した。パスワード/keyboard-interactiveのプロンプト、terminfo転送中の認証、別コンソール問題#72は未確認。

### 設定CLIと今回見つかった既存制約

通常ファイルへの出力では、両製品とも空direct/shellをexit 1、不完全UTF-8をexit 1、連続空白のdirect commandと1024文字のenvをexit 0で処理した。計10条件成功。`zig-out/n16-config-file-check.ps1`と`zig-out/logs/n16-config-*-file-*/summary.json`に保存。

一方、stdoutをpipeへ接続すると正常設定でもexit 1となる。ログは`CLI action failed error=error.FileTooBig`。固定Bの通常版`1.4.0-windows+33709d14e`でも同じ結果を確認したため、Cの新規退行ではない。正式な修正は未実施で、pipe経路の成功を主張しない。

- C初回: `zig-out/logs/n16-config-windows-20261031-184437/summary.json`。
- Cログ有効: `zig-out/logs/n16-config-windows-logged-20261031-184454/summary.json`。
- B比較: `zig-out/logs/n16-config-windows-b-20261031-184458/summary.json`。
- `validate_config.zig`はstdout_writer.end()を呼ぶ。Zig 0.17のFile.Writer.endはflush後、positionalモードならsetLengthする。Windows実装はNtSetInformationFileのINVALID_PARAMETERをFileTooBigへ変換する。通常ファイル出力での成功との対応から、この終端処理が原因と推測される。APIの使い方の修正と専用回帰試験は別途必要。

既知の#66（設定ダイアログ試験の誤った所有者指定）、#69（間欠事象）、#72は引き続き未解決。物理IME、実GPU障害/sleep、SSHの対話認証とterminfo転送中の認証、最終耐久、署名配布受入は後続フェーズ。

### 画像・z2d描画

Debug版でKitty配置/リサイズ/スクロール/削除/フレーム切替/アニメーションを両製品で確認し、正常終了。UTF-8を明示したproducerで罫線・角丸・ブロック・三角形も描画し、両製品のstatic画像を目視確認した。
`zig-out/logs/n16-kitty-windows-utf8-20261031-184655`と`n16-kitty-gooztty-utf8-20261031-184704`に保存。
先行試行`windows-debug-20261031-184629`、`gooztty-debug-20261031-184640`はKitty色測定は成功したが、producerの出力文字コードにより一部のUnicodeが?になった。UTF-8指定後の画面を描画確認の根拠とし、先行ログも残した。

両snapshotのsrc/pkg/scripts/build差は実質`src/brand.zig`のみ。`verify-windows-parity.ps1`には改行差だけがある。`zig-out/n16-product-source-differences.json`に保存。

## 単体テスト結果

両製品とも全Zig試験95/95工程成功、主テスト4,244成功・67スキップ。固定Bの主4,211成功・65スキップに対し、33成功・2スキップ増。追加テスト一覧35件と一致する。Goozttyの集計4,259成功には補助テスト15件も含む。
通常/hookのWin32試験も両製品でexit 0。ビルド・GUI等の残りは段階台帳の実行結果を参照。


## 段階検証完了（未コミット）

| 項目 | Windows / Gooztty |
|---|---|
| Debug / 通常fast / hook fast | 各145/145工程成功 |
| 全Zig主テスト | 各4,244成功・67スキップ |
| Win32通常 / hook主テスト | 各196成功・1スキップ |
| GUI / parity両条件 / 制御GPU・電源復帰 | 両製品で成功 |
| 設定診断 | 各7/8。既知のOwnerCloseWithOtherWindowのみ同じメッセージで失敗 |
| lifecycle | 各37/37、基準Bとケース名一致、各4画像確認、残留なし |
| 版・manifest・icon・terminfo | 両製品の3成果物すべて整合 |
| 検証中のソース不変 | 両ドライバーSourceUnchanged=true |

[結果台帳](windows-november-c-results.json)と[lifecycle比較](windows-november-c-lifecycle-comparison.json)に保存。
設定診断スクリプトはexit 1、各ケースのアプリはexit 0・強制終了なし。トップレベルFailure=nullはドライバー完走であり、全試験合格を示さない。
自動生成lifecycle JSONのVisualInspection=Pendingは実行時点の値として残し、目視結果は集約台帳のVisualInspectionに記録した。
Goozttyのlifecycle用ビルドはWindowsのGUIと並行して先行実行し、正式wrapperで再確認した。GUIは並列実行していない。

Windowsのport-logは段階検証後に追記し、Windows側のマージでGoozttyへ取り込んだ。コードは不変で、最終パッチを`zig-out/n16-windows-final.patch`に保存。
root Goozttyのport-logは編集していない。Goozttyの確定マージコミットである。
検証時の版表示はWindows `1.4.1-windows+cbf203f9e`、Gooztty `1.4.1-HEAD+f5f4e7474`。確定した合格SHAはWindows `06d12a298958ee97ee3d46b0c7f16658eeca8a21`、Gooztty `281c300aee9cbc42f7a5ff08ab62561a113aa3b9`。
Goozttyマージ時に`dist/windows/version.txt`を`1.4.1-windows.1`へ整合。開発段階の版であり、最終配布候補はN17で確定する。

tque #243およびP3をマージ後に完了へ更新。今回の結果を物理IME/実SSH認証/実GPU障害/sleep/最終耐久/署名配布物の受入に読み替えない。


