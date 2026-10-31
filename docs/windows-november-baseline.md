# N04: Zig 0.16 比較基準（2026-10-31）

[11月計画](windows-plan-2026-11.md)第5節に沿う実施記録。自動比較とGoozttyの追加画像確認を記録し、実IMEと終了確認を完了。既知の失敗を含む比較基準としてN04を完了した。
[コマンド別の結果と成果物台帳](windows-november-baseline-results.json)も保存する。

## 固定条件

| 対象 | コミット | 作業場所 |
|---|---|---|
| Windows | `ac3ad2b6cb615469b4e458a4128e1f643d7753df` | `.worktrees/windows-nov`、`windows`ブランチ |
| Gooztty | `07be8fc21e7dd1c699d13d89e734b4e0cd51f234` | `.worktrees/n04-gooztty`、detached HEAD |

両作業ツリーは開始時にクリーン。元のGooztty作業ツリーの編集中文書は保持する。
Zigは既存の0.16.0。ConPTYは`fetch-conpty.ps1`で固定版1.24.260710001を照合する。
通常/hookを別prefixへ直接ビルドし、ReleaseFast、cpu=baseline、emit-docs=falseを指定する。
版の上書き・配布パッケージ作成はしない。

検証用グローバルキャッシュは`zig-out/n03-clean-cache`。Zig 0.16の実際のパッケージ展開先は
各作業ツリーの`zig-pkg`。driverが設定した`ZIG_LOCAL_PKG_DIR`は0.16では反映されないことを
`zig env`と生成先から確認した。最後のパッケージ一覧収集は実際の`zig-pkg`から別途補足する。
lifecycle wrapperは自身の仕様に従って`.zig-cache/global`へ切り替える。
既存wrapperが`Get-Command pwsh`を使うため、検証プロセスのPATHから他のPowerShellインストールだけを除外し、
現在のPSHOMEを残す。ユーザー/システムのPATHは変更しない。

実行用driverは`zig-out/n04-run.ps1`。各stepのコマンド・引数・開始終了時刻・終了コード・ログと、
ソース/依存定義・exe/リソースのhashを保存する。失敗した試験は記録し、独立して実行できる後続試験を続ける。
アプリのGUI試験は並列実行しない。

Goozttyはdetached HEADのため、ブランチ名から生成される版文字列も記録する。
製品名・アイコン等の意図した差分と派生版があるので、両製品のexe hash一致は合否基準にしない。

## 実操作の扱い

日本語IMEの部分確定・フォーカス復帰・非同期出力時の表示は所有者の実操作が必要。
自動配置検査や合成キーの成功で代用しない。今回の実施状況を自動試験とは別に記録する。
実GPU障害・実sleep、180分耐久は今回のN04の自動成功には含めない。

## 結果

自動試験の結果を以下へ記録する。追加の表示・実IME・終了確認も完了し、N04は比較基準の記録として完了。既知不具合の修正完了を意味しない。

| 項目 | Windows | Gooztty |
|---|---|---|
| Debugビルド | 成功 | 成功 |
| 全Zigテスト | 4,123成功、64スキップ | 4,123成功、64スキップ |
| Win32通常 / hook | 各197成功、1スキップ | 各197成功、1スキップ |
| ReleaseFast通常 / hook | 両方成功 | 両方成功 |
| 通常GUI（wakeup/scrollbar/palette付き） | 初回失敗、同exeでの再試行1回は成功 | スクロールバー最下部の位置確認で初回・再試行とも失敗 |
| wakeup/palette独立確認 | 通常GUI再試行で成功 | scrollbarを含めない独立試験は成功、画像未検証 |
| parity継承有効 | 初回OSC 22手形確認で失敗、同exeでの再試行1回は成功 | 初回自動成功、再試行はOSC 22手形確認で失敗。画像未検証 |
| parity継承無効 | 成功 | 初回・再試行とも自動成功、画像未検証 |
| 設定診断 | 7/8成功 | 7/8成功 |
| GPU/復帰の制御試験 | 成功 | 成功 |
| IME自動 | 成功 | 成功 |
| lifecycle | 37/37成功、残存0、通常版HooksDisabled成功、4画像確認済み | 37/37成功、残存0、通常版HooksDisabled成功、4画像確認済み |
| 実IME | 部分確定・フォーカス復帰・非同期出力中の配置を所有者確認済み | 同左 |

### 失敗・画像の制約

- Windows通常GUI初回: `temporary pane scrollbar before close-during-drag`の検出がタイムアウト。
  palette/scrollbarの画像には他の画面が重なっていた。rendererの70batch完了画面と分割画面は確認できた。
- Windows継承有効parity初回: `OSC 22 hand cursor`がタイムアウト。診断には`Flags=2`と
  foreground/expected windowの相違が記録された。画面の重なりと失敗の因果関係は未確定。
- Windowsの通常GUIと継承有効parityは、同じ通常ReleaseFast exeで各1回だけ再試行し成功した。
  前後のhashは同じ。再試行のpalette/scrollbar/split画像は対象が遮られず確認できた。
  初回失敗を削除せず、#69/N19の間欠性の調査資料とする。修正済みとは扱わない。
- Gooztty通常GUI: `bottom scrollbar position`でタイムアウト。
  最終測定値は`top=374, height=13, bottom=387, track=949`。
  palette/scrollbarと両parityのキャプチャには検証対象が写っておらず、別画面が写っていた。
  自動成功のparityも表示の受入は未検証とする。製品の描画不具合と断定せず、画面を確保して再確認する。
- Goozttyの同exeでの再試行1回でも通常GUIは失敗し、測定値は`top=905, height=14, bottom=919, track=949`。
  継承有効parityは手形確認で失敗し、その診断では`WindowClass=MozillaWindowClass`、
  foreground/expected windowの相違を確認した。継承無効parityは再び成功した。
  これらの再試行画像にも検証対象が写っていない。初回・再試行のexe hashは同じ。
  前面・ポインターの条件を確保せず、製品の不具合や修正済みを結論づけない。
- Goozttyではscrollbarによる途中終了の後、同exeでwakeup/paletteだけを独立確認し成功した。
  これで全GUI試験を合格扱いにはしない。独立試験の画像も別画面であり、表示の受入は未検証。
- 両版の設定診断: `OwnerCloseWithOtherWindow`だけが
  `Stale diagnostic survived its owner`で失敗。他7ケースは成功し、全8プロセスはexit 0・強制終了なし。
  #66/N02に渡す再現記録であり、原因特定・修正完了ではない。

### 版・依存・リソース

| 対象 | 版 | 通常ReleaseFast exe SHA256 | hook ReleaseFast exe SHA256 |
|---|---|---|---|
| Windows | `1.3.2-windows+ac3ad2b6c` | `4D8212E6110291829AE7361A7B53436A2D1363F89BFB4D088BAAC8E9E776CEBB` | `3A456955737C45920F8225F7C32C8BE16575B3B20B3D384901106A459A789232` |
| Gooztty | `1.3.2-HEAD+07be8fc21` | `F33CC3CF5E60DE0D45F56A1A7C3632DB7D95E1060613BCE75F04D45758A1E21E` | `EA12215F621B116151CE7060673ED335D0D92C9917C7B29C1F05FE29E587A069` |

両版のDebug/通常ReleaseFast/hook ReleaseFastの計6成果物について、CLI・FileVersion・ProductVersionが一致。
埋め込みmanifestはソースと一致し、大小アイコンを抽出できた。製品別brand.json、shell-integration、themes、
terminfoソースとコンパイル済みエントリ2件を確認した。同梱ConPTY 2ファイルのhashはvendorと一致し、
実行ログはsideloaded conpty.dllの使用とIOCP backendを報告した。

## 証拠の場所

| 対象 | 作業ツリー内の`zig-out/logs/`からの相対パス |
|---|---|
| Windowsのコマンド・ソース・exe台帳 | `n04-20261031-134611-469/summary.json`と`source.json` |
| Windowsのリソース照合 | 同ディレクトリの`resources.json`と各variantの`*-files.json` |
| Windowsの再試行 | 同ディレクトリの`repeat.json`、`normal-gui-repeat.log`、`parity-enabled-repeat.log` |
| Windows IME自動 | `ime-verification-20261031-140548-634/summary.json` |
| Windows lifecycle | `lifecycle-acceptance-20261031-140806-347.json`、同`-cases.json` |
| Windows設定診断 | `config-diagnostics-20261031-140530-923.json` |
| Goozttyのコマンド・ソース・exe台帳 | `n04-20261031-135311-377/summary.json`と`source.json` |
| Goozttyのリソース照合 | 同ディレクトリの`resources.json`と各variantの`*-files.json` |
| Goozttyの再試行 | 同ディレクトリの`repeat.json`と`*-repeat.log` |
| Goozttyのwakeup/palette独立確認 | 同ディレクトリの`wakeup-palette.json`と同`.log` |
| Gooztty設定診断 | `config-diagnostics-20261031-141225-309.json` |
| Gooztty IME自動 | `ime-verification-20261031-141243-368/summary.json` |
| Gooztty lifecycle | `lifecycle-acceptance-20261031-141428-878.json`、同`-cases.json` |

両版のdriverは全試験後、未対応の`ZIG_LOCAL_PKG_DIR`を一覧化しようとして終了コード1になった。
各試験の終了コードとは区別する。元のsummaryは保持し、実際の`zig-pkg`から
各台帳ディレクトリへ`resolved-packages-supplement.json`を採取した。両版とも`SourceUnchanged=true`を確認済み。
Windowsで実行したdriverはルートの`zig-out/n04-run-windows-used.ps1`に保存。
GoozttyのdriverにはWindowsのGUI終了まで待つゲートだけを追加した。ゲートはWindowsの再試行まで終了し、
その作業ツリーのテストexeが残っていないことを確認してから開いた。

## 残る確認と次の手順

N04はtque #223で完了。N03とN04が揃ったため、N05の依存条件を満たした。

1. Goozttyの追加確認は14:22〜14:23に実施済み（下記）。残るscrollbar失敗はN19の調査対象とする。
   実行中は他のウィンドウを前面に出す操作を控え、キャプチャに対象が写っていることを確認する。
   同じexeを使い、今回の失敗ログを保持する。条件が揃っても失敗する場合はN19へ分離する。
2. 両版の通常ReleaseFastで日本語IMEの部分確定・フォーカス離脱/復帰は所有者確認済み。非同期出力中の配置も後述の追加試験で所有者確認済み。
   ルートからの起動例は以下。記録用ウィンドウでは入力はコマンド実行されず、F10で終了する。
   自動IMEの結果を実操作の代わりに使わない。非同期出力中の追加試験は末尾に記録する。
3. #66/N02と#69/N19へ今回の再現条件・ログを渡し、比較基準の未解決項目として維持する。

```powershell
$exe = (Resolve-Path '.worktrees/windows-nov/zig-out/n04-20261031-134611-469-normal/bin/ghostty.exe').Path
pwsh -NoProfile -File .worktrees/windows-nov/scripts/test-windows-ime.ps1 -Executable $exe

$exe = (Resolve-Path '.worktrees/n04-gooztty/zig-out/n04-20261031-135311-377-normal/bin/gooztty.exe').Path
pwsh -NoProfile -File .worktrees/n04-gooztty/scripts/test-windows-ime.ps1 -Executable $exe
```

今回の自動比較では製品コードを変更せず、upstreamの統合・新規コミット・pushも行っていない。

## 追加の表示確認（2026-10-31 14:22〜14:23）

同じGooztty通常exe（SHA256は上表と一致）で通常GUIとparity両条件を順次再実行した。
台帳は`.worktrees/n04-gooztty/zig-out/logs/n04-attended-20261031-142222/summary.json`。
parityは両条件exit 0。通常GUIはclose-during-drag前の一時ペインのscrollbar検出でタイムアウトしexit 1。
失敗を保持し、GUI全体の合格や#69の修正完了とはしない。

同logs内の`window-state-20261031-142222-913-4df5cd95`のpalette、renderer、scrollbar、
scrollbar-split画像と、`parity-20261031-142331-562.png`、`parity-20261031-142339-937.png`を確認した。
今回は対象画面が写っており、コマンドパレット、描画出力、スクロールバー、分割、検索結果の表示を確認できた。
以前の別画面が写った画像は表示の証拠に採用しない。部分確定・フォーカス復帰の実操作結果は次節に記録する。非同期出力中の配置も後述の追加試験で所有者確認済み。

## 実IMEの所有者確認（2026-10-31）

Windows版、Gooztty版の順に通常ReleaseFastで部分確定とフォーカス離脱・復帰を確認し、
所有者から「2つとも問題ない」との報告を受けた。この2項目を両版とも確認済みとする。

- Windows: `.worktrees/windows-nov/zig-out/test-fixtures/ime-20261031-142518-653/session.json`
- Gooztty: `.worktrees/n04-gooztty/zig-out/test-fixtures/ime-20261031-142643-093/session.json`

両版ともexe hashは比較基準と一致し、終了コード0。親と観測したprobeは終了、残存PIDなし、
ログ上のcrash/leak検出なし。通常版のためTracePresent=false。表示の判定根拠は所有者の報告であり、
終了ログだけから判定していない。この手順に含まれない非同期出力中の配置は、次節の追加試験で確認した。
追加試験の終了確認まで完了し、N04を完了した。

## 非同期出力中の実IME確認（2026-10-31）

専用harness `zig-out/n04-async-ime.ps1`で500msごとに出力して入力位置を移動させ、
Windows版、Gooztty版の順に変換中と部分確定後の表示位置を所有者が確認した。
所有者から「ＯＫ」と報告されたため、両版の表示を確認済みとする。
証拠は`zig-out/n04-async-ime-20261031-142829/`の製品別ディレクトリ。
両版ともexit 0、probe終了、crash/leak検出なし。exe hashも比較基準と一致。
所有者の終了報告後もGoozttyの出力が続いていたため、対象PID・exe・タイトルを照合してCloseMainWindowで通常終了した。強制終了はしていない。N04を完了し、N05の依存条件を満たした。#66/N02と#69/N19の失敗記録は残す。
