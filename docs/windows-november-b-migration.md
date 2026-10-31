# N15: 固定点Bへの統合（2026-10-31）

P0調査完了後に再開。固定Bの競合解消とWindows/Gooztty両製品のスナップショット検証を完了した。既知の設定診断1件は失敗のまま記録。2026-10-31にWindows `33709d14e`、Gooztty `d9cbeef`としてマージした。確定コミットでの追加照合結果は末尾に記録する。

- 基準Windows: c6669ed65a74029f8d22799ab7fee77a7764ac12
- 基準Gooztty: f2b98c662f677c6f23a900a8cb3f8df6aaf116b4
- 固定B/main: 83fb95624b0439ee660c2679b43b38c8b63769cd、1.4.0、Zig 0.17.0
- Windows: `.worktrees/windows-nov`で`merge --no-commit --no-ff main`。
- `zig-out/toolchains/zig-x86_64-windows-0.17.0/zig.exe`と`n03-clean-pkg-b`を使用。

## 競合解消

- フォークで削除したupstream CI・VOUCHED・PACKAGINGは削除を維持。
- Surface: 上流のenv所有権移譲前のスコープに、ブランド環境変数とWindows旧ブランド変数除去を移動。Exec.init失敗時の二重解放を戻さない。
- Kitty描画: 上流のRenderState更新前のanimationTickを採用し、二重のtickを除去。新しい世代ベースの配置更新とimages_rebuiltを取り込み、Windows GPU復帰のforce_image_rebuildを保持。
- 端末mode: Win32入力9001を保持。GTKのKitty clipboard対応は上流に合わせ、未対応のWindowsアプリだけpaste eventsを無効化。libghostty-vtでは無効化しない。

## 検証方針

`zig-out/n15-run.ps1`で各ソース・依存・成果物hashと終了コードを記録。
Debug/通常fast/hook、全Zig試験、Win32通常/hook、通常GUI/parity、GPU/電源復帰制御、lifecycleを実施。
既知の設定診断の誤った所有者assertは残したまま、#66のP0調査と区別して結果を記録する。
lifecycleの37件・4画像を変更せず照合する。画像配置・履歴・初期化解放・SSH/SetEnv・shell integrationが重点項目。

新規コミット・Gooztty本ブランチへの統合・合格SHA記録は未実施。

## 追加の重点確認

- 初回Windows/Gooztty Debugビルドは各145/145工程成功。
- `zig-out/n15-kitty-check.ps1`とproducerで実画像を描画。通常配置、リサイズ、2行スクロール、特定画像削除、静止フレーム切替、連続アニメーション、全削除の色測定と画像を保存。
  Windows: `zig-out/logs/n15-kitty-windows-debug-20261031-160134/summary.json`。
  Gooztty: `zig-out/logs/n15-kitty-gooztty-debug-20261031-160156/summary.json`。
  両方成功・exit 0。Windows静止/青フレーム、Goozttyリサイズ画像を確認済み。
  最初のWindows試行`160051`は検証器がMainWindowHandleを取得できず失敗。PID/クラスで対象を特定するよう検証器を修正した。初回失敗ログと後片付け記録も保持。
- SSHは外部接続の代わりに引数/TERMをファイルへ出す`n15-ssh-probe.exe`を指定。
  forward有効、両機能無効、remote commandでterminfo有効の3条件を両製品で実行し、全6条件exit 0。
  ユーザーの`SetEnv=EDITOR=vim`を保持し、追加の`SetEnv=TERM`を注入していないこと、期待するTERMを確認。
  `zig-out/n15-ssh-results.json`を保存。実SSHサーバーの認証やAcceptEnvの受入を確認したという意味ではない。
- lifecycleスクリプト2本は基準Aから差分なし。件数と画像数の変更は行わない。
- Bashのcwd報告は実際の`__ghostty_precmd`関数を抽出して制御文字入りHOSTNAME/PWDで実行。OSCのESC/BELが枠の2個ずつに留まり、OSC52注入がなく、通常のbackslashは保持された。syntax/実行exit 0。`zig-out/n15-bash-cwd-results.json`。zshの実行環境での受入は未実施で、差分確認に留まる。
- Windows全Zigテスト: 95/95工程、主テスト4,211成功・65スキップ。通常Win32: 196成功・1スキップ。

Windowsの通常GUI/parity両設定/GPU・電源復帰制御は成功。設定診断はOwnerCloseWithOtherWindowのみ従来のassert失敗（試験スクリプトはexit 1、各ケースのアプリはexit 0・強制終了なし）で、P0調査と同じケース。全3成果物の版・manifest・icon・terminfo照合も成功。lifecycleは37/37成功・4画像を確認済みで、基準Aからケース名は不変、残留プロセスなし。`windows-november-b-lifecycle-comparison.json`に対応表を保存した。

- Kitty画像を表示したhook版で制御GPU復帰を追加確認。両製品で復帰カウンター0→1、復帰後の赤/緑画像保持と後続アニメーションが成功、exit 0。復帰直後画像を両方確認済み。
  `zig-out/logs/n15-kitty-windows-hooks-gpu-20261031-161648`と`n15-kitty-gooztty-hooks-gpu-20261031-161710`。
  最初のGPU用試行`161633`は検証器が直下の子だけを探して失敗。実際のpaneを子孫から特定するよう検証器を修正し、失敗ログも保持。製品ソースは変更していない。
- Gooztty全Zigテストも成功。主4,211成功・65スキップ、補助15成功で総計4,226成功。通常/hook Win32の主テストは各196成功・1スキップ。先行fast通常/hookビルドも各145/145成功。
- upstream由来の`src/terminal/snapshot/verify-kaitai.py:649`に末尾空行のdiff-check警告がある。競合解消3ファイルのfmtは成功し、未解消競合はない。


## 確定前の扱い

Windowsの最終パッチは`zig-out/n15-windows-final.patch`に保存。検証開始時のsource.json/working-tree.patchに加えて、検証後に追記したWindows port-logを含む。アプリケーションソースは検証後に変更していない。
Gooztty側はdetached snapshotによる事前検証で、本ブランチへのマージではない。N15の合格SHAはマージコミット後に記録し、それまではN16へ進まない。

現在の配布用`dist/windows/version.txt`は`1.3.2-windows.17`のまま。Bのコアは1.4.0なので、実際のGooztty統合時にチェックリストに従って数値基盤を整合させる。N17の最終版確定や署名配布物の検証を今回の直接ビルドで代替しない。


## 両製品の段階検証結果

| 項目 | Windows | Gooztty |
|---|---|---|
| Debug / fast通常 / fast hook | 各145/145工程成功 | 各145/145工程成功 |
| 全Zig試験 | 主4,211成功・65スキップ | 主4,211成功・65スキップ |
| Win32通常 / hook | 各196成功・1スキップ | 各196成功・1スキップ |
| 通常GUI / parity両条件 | 成功 | 成功 |
| 設定診断 | 7/8、既知の所有者assertのみ失敗 | 7/8、同一ケース・同一メッセージ |
| 制御GPU / 電源復帰 | 成功 | 成功 |
| lifecycle | 37/37、4画像を目視確認 | 37/37、4画像を目視確認 |
| 版・manifest・icon・terminfo | 3成果物すべて整合 | 3成果物すべて整合 |
| 検証中のソース不変 | true | true |

Windows台帳: `.worktrees/windows-nov/zig-out/logs/n15-b-20261031-155820-299/summary.json`。
Gooztty台帳: `.worktrees/n15-gooztty/zig-out/logs/n15-b-20261031-162009-836/summary.json`。
集約台帳は[windows-november-b-results.json](windows-november-b-results.json)、ケース対応は[windows-november-b-lifecycle-comparison.json](windows-november-b-lifecycle-comparison.json)。

Goozttyの最終全テストは先行試験後に再実行され、同じ主テスト4,211成功・65スキップだった。以後の追加再実行は行っていない。
設定診断の失敗ケースは`OwnerCloseWithOtherWindow`、`Stale diagnostic survived its owner`。試験スクリプトはexit 1、各ケースのアプリはexit 0・強制終了なし。台帳のトップレベル`Failure: null`は検証ドライバー自体の完走を示し、全試験合格を意味しない。正式な試験修正は未実施であり、この失敗を合格に書き換えない。
lifecycleは両製品とも基準Aの37ケースと一致し、残留プロセスなし。自動生成のwrapper JSONにあるVisualInspection=Pendingは実行時の値として保存し、目視確認の結果は集約台帳のVisualInspectionに追記する。
Goozttyではrenderer、split scrollbar、paletteの通常GUI画像も確認済み。最終確認時に残っていた製品プロセスは利用中のインストール版PID 34560のみで、操作していない。

Goozttyの成果物はdetached HEAD由来の`1.4.0-HEAD+f2b98c662`と表示される。Bを含む未コミット内容はsource.jsonとworking-tree.patchで特定し、この表示SHAだけをB合格コミットとして扱わない。
Debug SHA256: `D2D906319699CFE2B066D5893D2AC58ED9951EAA4BEC0AF133A1D2B5BAE031B5`。
通常fast: `17B8D83E5CBDFAE176AF20098CB95C577B94C3A409BB06BC53374AB339A32CCA`。
hook fast: `606D43903C8AC1C65B00A93236484FA0677EBD37571BE0C825A13B827103028A`。

tque #242は「検証済・マージ待ち」の未完了を維持。N16は依存で停止。実IME、実機のGPU障害/スリープ、実SSH認証、署名配布物の受入は今回の検証対象に含まない。


## マージコミット（2026-10-31）

- Windows: `33709d14e98d591680cf6628f97e9ef99d7a16c9`。親は`c6669ed65a74029f8d22799ab7fee77a7764ac12`と固定B `83fb95624b0439ee660c2679b43b38c8b63769cd`。
- Gooztty: `d9cbeef564d5df3cc7fefd947e451d7c71bad650`。親は`f2b98c662f677c6f23a900a8cb3f8df6aaf116b4`と上記Windowsマージ。
- 本ブランチへの適用内容と事前検証snapshotを照合。16ファイルのCRLF/LF差を除きアプリケーション・build・pkg・scriptsは一致し、改行正規化後は全件一致。`zig-out/n15-actual-merge-source-comparison.json`。
- Windows/Gooztty間の該当コード差分は`src/brand.zig`だけ。Windows port-logは無変更でGoozttyへ取り込んだ。
- Goozttyの`dist/windows/version.txt`を採番規則に従い`1.4.0-windows.1`へ整合させ、changelog/release notesに開発段階の検証・既知失敗・未受入条件を記録した。N17での最終版確定とは区別する。
- 既存のAGENTS/ロードマップ等の作業は保持し、今回のマージコミットに混入させていない。プッシュ・タグ・パッケージ作成は行っていない。
- 上の「未コミット」「マージ待ち」記述は事前検証時点の履歴。確定SHAの追加照合は`zig-out/n15-verify-committed.ps1`で通常fastビルド、Win32テスト、CLI/FileVersionを確認する。

確定SHAでの通常fastビルド・Win32テスト・CLI/リソース版照合は両製品で成功。[確定コミット結果](windows-november-b-committed-results.json)にコマンド結果・hashを保存した。段階台帳の合格SHAを記入し、N15を完了。既知の設定診断失敗と最終受入の未実施条件は維持する。


Claude Codeレビューはコード上の確定欠陥なし。軽微な文書指摘と改善案への対応・確定コミット検証の証拠範囲は[レビュー対応記録](windows-november-b-review-response.md)を参照。
