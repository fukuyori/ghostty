# N05: 固定点Aへの移行（2026-10-31）

実装と両製品のスナップショット検証を完了し、所有者の指示でWindowsとGoozttyのマージコミットを作成した。確定SHAでの追加照合は成功。Claude Codeレビューで修正を要する欠陥はなく、N05を完了した。

## 対象と作業場所

- 固定A: `3d07ef9e28c4af05065b9e2e546b8ac8f9b62df0`。Zig 0.17.0、zon版1.3.2-dev。
- main: `.worktrees/main-nov`で固定Aへfast-forward。新規コミットは作成していない。
- windows: `.worktrees/windows-nov`、元HEAD `ac3ad2b6c`。`merge --no-commit --no-ff main`の未コミット状態。
- Gooztty事前検証: `.worktrees/n05-gooztty`、元HEAD `07be8fc21`。Windowsの作業差分を適用した検証用スナップショット。
  実ブランチのmergeや合格SHAの代替ではない。ルートの編集中文書は保持。
- ツール: `zig-out/toolchains/zig-x86_64-windows-0.17.0/zig.exe`。
  検証用cacheは`zig-out/n03-clean-cache`、packageは`zig-out/n03-clean-pkg-a`。

## 統合方針と修正

10ファイルの競合を解消。フォークで削除済みのupstream CIは復活させず、Windowsの同期I/O取消・
OSC 7のドライブパス対応・SSH ControlMaster回避・ブランド参照・版リソース生成を保持した。
Zig 0.17のallocator、型情報、ビット集合、enum変換、最適化列挙、文字列APIへWindows実装を移行。
D3D11の行列はupstream OpenGL/Metalと同様に`[4][4]f32`を使い、既存のサイズ・オフセット検査を保持。
ビルド設定のicon/manifestとConPTY検出にはconfigure cacheの依存を登録した。ただしWindowsで呼ぶZig 0.17のfindProgramがconfigure cacheを無効化するため、現状でキャッシュが有効になったという意味ではない。
PowerShellの最適化指定は`fast`へ変更。パッケージ作成・版変更は行っていない。

## 検証記録

- `zig-out/n05-build-01.log`〜`n05-build-07.log`: 移行途中のコンパイル失敗を保持。
- `zig-out/n05-build-08.log`: Windows Debug、145/145工程成功。後続の最終ソース検証とは区別。
- `zig-out/n05-fast-initial.log`: Windows fast、145/145工程成功。
- `zig-out/n05-test-01.log`: D3D11試験fixtureの行列型でコンパイル失敗。fixtureも変換して再実行した。
- `zig-out/n05-test-02.log`: 全Zigテスト成功（95/95工程、主テスト4,108成功・64スキップ、補助テストは成功済みキャッシュ）。
- `zig-out/n05-run.ps1`: 両製品の段階検証driver。実行結果は各作業場所の`zig-out/logs/n05-a-*`へ保存する。
- Zig fmt/AST検査と変更したPowerShell 3本の構文検査は成功。
- `git diff HEAD --check`はupstreamの`nix/patches/zig-0.17-ios-process-replace.patch:8`を報告する。
  patchの空行コンテキストの先頭スペースであり、パッチの意味を変えないよう維持。移行作業差分の`git diff --check`は成功。

以下はマージ前に取得した検証記録。確定コミットの情報は末尾の台帳に記録する。
合格SHAとレビュー結果は後述の台帳・確認文書に記録済み。

## Windowsの段階検証

台帳: `.worktrees/windows-nov/zig-out/logs/n05-a-20261031-150305-776/summary.json`。
`SourceUnchanged=true`、driver終了コード0。作業差分、ソースと依存hash、各コマンドと終了コードを保存した。

| 項目 | 結果 |
|---|---|
| Debug / fast通常 / fast hook | 各145/145工程成功 |
| 全Zigテスト | 95/95工程成功。主テスト4,108成功・64スキップ、補助テスト成功 |
| Win32通常 / hook | 主テストは各196成功・1スキップ。補助の1件が実行かcachedかで総計表示は197/196となる。N04の主テスト件数と同じ |
| 通常GUI/IO（wakeup/scrollbar/palette） | 成功、palette/renderer/scrollbar/splitの4画像確認済み |
| parity継承有効 / 無効 | 両方成功、検索画面2画像確認済み |
| GPU / 電源復帰の制御試験 | 成功。実GPU障害・実sleepの受入とは別 |
| IME自動 | `ime-verification-20261031-150801-836/summary.json`、AutomatedPassed=true |
| 設定診断 | 7/8成功。N04と同じOwnerCloseWithOtherWindowのみ失敗（Stale diagnostic survived its owner）。全プロセスexit 0、強制終了なし |
| リソース | 3成果物ともCLI/FileVersion/ProductVersion一致、manifestはソースと一致、大小icon抽出、terminfo・ConPTYを照合 |

通常fast exe SHA256: `AF7FADDAA5FE708636F603295078EEF8CF2CEB6E54E927EC9ABDA14D0AB18773`。
hook fast exe SHA256: `B6591CE6CC1B4D233B0476B95A872308375900345CB3CED5D5B39765EA0F3F12`。
版は`1.3.2-windows+ac3ad2b6c`。未コミットのためSHA部分だけでは検証ソースを特定できず、台帳のpatch/hashと組み合わせる。
通常GUIの画像は`window-state-20261031-150628-460-92b058c6.*.png`、parityは`parity-20261031-150727-945.png`と`parity-20261031-150736-365.png`。
過去の#69の間欠失敗が解消したという判定はしない。今回の0.17での実キー・実IME受入は未実施。

### OpenGL経路の追加確認

WindowsのOpenGL選択ビルドで`Device.init`の戻り値不足を検出した（`zig-out/n05-opengl-build.log`）。
割り当てたdeviceを返すよう修正し、`n05-opengl-build-02.log`では145/145工程成功。
D3D11通常fastも再ビルドし（`n05-default-after-opengl.log`）、exe SHA256が上記AF7F…と完全一致した。
段階検証後のコード変更はこのOpenGL経路のみで、既定D3D11の実行ファイルは不変。
追加記録はWindows台帳内`opengl-followup.json`。OpenGL実機GUI・描画更新・正常終了も成功（`zig-out/n05-opengl-gui.json`）。renderer画像を確認済み。Goozttyにも同じ修正を反映し、通常fastを再ビルドした。`zig-out/n05-gooztty-after-opengl.json`で通常版のSHA256完全一致を確認。両製品のAGENTSのWASMコマンド例も`small`へ更新した。

## Goozttyスナップショットの検証

台帳: `.worktrees/n05-gooztty/zig-out/logs/n05-a-20261031-150939-292/summary.json`。
Debugは145/145工程成功、全テストは95/95工程成功（主4,108成功・64スキップ、補助5+10成功）。
Windowsの全テスト総計との差は補助テスト15件がcachedか実行かによるもので、主テスト件数は同じ。
Debug / fast通常 / fast hookは各145/145工程成功。Win32通常・hookは主テスト各196成功・1スキップ。
通常GUI（描画更新・scrollbar・palette）、parity両設定、GPU/電源復帰の制御試験は成功。
通常GUI4画像とparity2画像を確認した。IME自動は`ime-verification-20261031-152530-799/summary.json`で`AutomatedPassed=true`。
設定診断はWindowsと同じ7/8成功で、OwnerCloseWithOtherWindowのみ既知失敗。
3成果物の版・manifest・icon・terminfo・ConPTY照合も成功。driverは終了コード0、`SourceUnchanged=true`。

通常fast exe SHA256: `EF13B3743CC24CFFAD26267A89499ECA35A7382828F45A65A9C13252C76406E7`。
hook fast exe SHA256: `6EF3DA3752E253FF5D517A65F625AA148973DC00092D3AF71331FB03D192829A`。
版は`1.3.2-HEAD+07be8fc21`。Windowsと同様に未コミット差分・ソースhashと組み合わせて識別する。
OpenGL修正後の通常fastも145/145工程成功、上記通常版hashと一致した。
試験用プロセスの残存はなく、既存のインストール済みGoozttyは操作していない。

## 完了確認

- Windowsのマージコミットを作成済み: `c6669ed65a74029f8d22799ab7fee77a7764ac12`。
- Gooztty本ブランチへ統合済み: `f2b98c662f677c6f23a900a8cb3f8df6aaf116b4`。既存の編集中文書はコミット外で保持した。
- 確定SHAでの通常fastビルド・Win32試験・版/資源照合を完了し、main/windows/goozttyの段階合格SHAを台帳へ記録した。
- Claude Codeレビューを確認し、N05を完了した。レビューの注記と読取り時点の差異は[確認文書](windows-november-a-review-response.md)に記録した。N15の依存を解除する。

今回の実キー・実IMEによる受入、実GPU障害・実sleep、署名・パッケージ・配布は実施していない。
N04の実IME受入を0.17の受入として転用しない。最終の実機受入は計画のN06で行う。


## 確定コミット台帳

| 枝 | 統合前 | 統合後 |
|---|---|---|
| main | b58ef1d678be2747c830bc1b1e6c0a086afecf9a | 3d07ef9e28c4af05065b9e2e546b8ac8f9b62df0 |
| windows | ac3ad2b6cb615469b4e458a4128e1f643d7753df | c6669ed65a74029f8d22799ab7fee77a7764ac12 |
| gooztty | 07be8fc21e7dd1c699d13d89e734b4e0cd51f234 | f2b98c662f677c6f23a900a8cb3f8df6aaf116b4 |

両マージの親を確認済み。Goozttyのsrc/pkg/scripts/build/distは検証スナップショットと一致
（比較時は改行を正規化）。Windowsのport logはGoozttyへ同一blobで到着した。
版の数値ベースはzonの1.3.2-devとversion.txtの1.3.2-windows.17で一致し、版変更なし。
追加照合のコマンドは`zig-out/n05-verify-committed.ps1`、結果は`zig-out/n05-committed-validation.json`。
レビュー依頼は[依頼文](windows-november-a-review-request.md)、回答は[Claude Codeレビュー](windows-november-a-claude-review.md)へ保存する。
タグ・push・パッケージ作成は実施していない。

### 確定SHAでの追加照合結果

両製品の通常fastビルドは145/145工程成功。Win32テストも各95/95工程成功。
主テストは各196成功・1スキップで、Goozttyの総計197成功は補助テスト1件を含む。
CLI/FileVersion/ProductVersionの一致、manifest・大小icon・terminfo・ConPTY照合も成功した。
結果は[確定SHAの結果JSON](windows-november-a-committed-results.json)、リソース詳細は
`zig-out/n05-committed-{windows,gooztty}-resources/resources.json`に保存。

| 枝 | 通常fastの版 | SHA256 |
|---|---|---|
| windows | 1.3.2-windows+c6669ed65 | 633237C3F2BED91CE64A471AA69ADEBC948F4BB162D2C3E351AA3FD582E31975 |
| gooztty | 1.3.2-gooztty+f2b98c662 | 51987A3D7D942AF7A06C34E8F7B63E2FCDDB9298BBA61DBB0D7FF8198783A787 |

コミットにより版文字列が変わるため、マージ前のexe hashとは区別する。
GUI・GPU/電源制御・IME自動の証拠は同一ソースのマージ前スナップショットによるもので、
この追加ビルドでGUI一式を再実行したとの主張はしない。確定SHAではビルド・Win32・資源を照合した。


