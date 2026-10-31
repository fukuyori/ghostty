# 11月移行の事前確認（2026-10-31）

[11月計画](windows-plan-2026-11.md)のN01/N03の作業記録。両タスクは完了。
upstreamの実統合とZig 0.17でのWindowsアプリのビルド・受入は、後続フェーズで行う。

## 固定したupstream

Gitオブジェクトを取得し、以下の`build.zig.zon`と依存差分を読んだ。upstreamのブランチへの統合は未実施。

| 段階 | 固定SHA | zonの版 | minimum_zig_version |
|---|---|---|---|
| A | `3d07ef9e28c4af05065b9e2e546b8ac8f9b62df0` | `1.3.2-dev` | `0.17.0` |
| B | `83fb95624b0439ee660c2679b43b38c8b63769cd` | `1.4.0` | `0.17.0` |
| C | `fbed180a5f181915c92a8f2f561903a6e4645b5a` | `1.4.1-dev` | `0.17.0` |

比較元は`b58ef1d678be2747c830bc1b1e6c0a086afecf9a`。N03では以下を依存監査の対象とする。

| 区間 | 確認した主な変更 |
|---|---|
| 比較元→A | libxev、vaxis、z2d、zig_objc、uucode、zig_wayland、zf、gobjectの更新。translate-cは0.16向けbackportから2.0.0へ。fontconfigは取得URL変更、package hashは同じ |
| A→B | z2dを0.13.0へ、iTerm2テーマを20261019版へ |
| B→C | z2dを0.13.2へ。vaxisの推移依存zigimgをmirrorから非lazyで固定 |

Windowsで使用する依存と他OS専用依存は分けて確認する。固定先の
`build.zig.zon`、`pkg/*/build.zig.zon`、`build.zig.zon.json`を取得元・hashの根拠とする。
取得・実行確認とライセンスの結果は末尾のN03完了記録を参照。配布物への同梱確認はN18で行う。

## ビルドと再現性（レビューG01/G03）

- 作業場所はリポジトリ内`.worktrees/`。`.git/info/exclude`でローカル除外した。
  `windows`の実作業場所は`.worktrees/windows-nov`。各作業場所のConPTYを準備する。
- 今回のConPTYは既存checkoutからコピーし、`fetch-conpty.ps1`の既存ファイル検証でhashを照合した。
- Zig 0.16.0と0.17.0を実行確認済み。
  Aの`src/build/Config.zig`は`std.lang.Optimize`と`.debug/.safe/.fast/.small`を使う。
  A/B/Cの`zig build --help`で`-Doptimize=fast`を確認した。
- 中間段階の直接ビルドでは版を上書きしない。0.16側の最適化指定は`-Doptimize=ReleaseFast`。
  各段階で空の出力先、`-Dcpu=baseline -Demit-docs=false`、ツール版と全引数を記録する。
- `src/build/GitVersion.zig`と`Config.zig`ではブランチ名・SHA・タグ・dirty状態が版の生成に関係する。
  detached HEADでの再現時には元のブランチ名と派生版も記録する。
  同じソースでも版文字列等が異なる場合、hash一致だけを合否に使わず、差の原因と機能試験を評価する。
  exact tagがある場合はzonの版との整合も確認する。
- N17の最終候補はクリーンな固定SHAを必須とする。今回の未コミット状態での検証は開発中の証拠に限る。

## 実操作と代替候補（レビューG02/G04）

通常exeのIME実操作では`TracePresent=false`を想定する。traceが必要な検証は同じソースの
hookビルドで別に行い、通常exeの実操作の代替にしない。

11/20にA/Bを代替候補にする場合は、所有者の選択、対象SHA・版・依存の再設定、必要な版更新の
コミットと統合を11/25の凍結期限内に終える。判断待ちも期限内に含める。
過去候補を選ぶだけでreset/revertの実行を許可されたとは扱わない。
期限に間に合わなければN06/N11を延期し、受入期間を短縮しない。

## N01の変更と残件

変更は`windows`の作業ツリーにある。

- `test-windows-parity.ps1`: `-Executable`を省略するとエラーにし、古い既定exeを試験しない。
  exe/hash・失敗理由・終了コード・強制終了の有無をJSONに残す。
- `verify-windows-parity.ps1`: 新規出力先へビルドし、継承有効/無効の両方を実行する。
  HEAD・ブランチ・作業ツリー・ソース/ConPTY hash・Zig版・引数・終了コードを保存し、入力の変化を検出する。
- 構文確認と、exe未指定・存在しないパス・ディレクトリ指定の拒否を確認した。
- 最初のビルドは142/142成功。ビルド中にスクリプトを修正したため、入力変化の検出で実行を停止した。
  続く実行でPowerShellの複数インストールによるコマンド解決の不備を検出し、現在の`$PSHOME`を使うよう修正した。
  失敗記録は削除せず、最終実行とは分けて保存する。

最終実行`parity-verification-20261031-133059-678`では、142/142のビルド工程と継承有効/無効の
両試験が成功し、終了コード0、`InputsUnchanged=true`を確認した。各試験の画面キャプチャで
検索欄・ハイライト・日本語文字列も確認した。各1回の成功であり、#69の間欠不具合の解消や実IMEの受入は意味しない。
詳細なログ名とexe hashはwindows側のport logに記録した。

### N01完了（同日追記）

所有者の指示を受け、Windows側の3ファイルを`ac3ad2b6c`でコミットし、
Goozttyへ`07be8fc21e7dd1c699d13d89e734b4e0cd51f234`でmergeした。pushはしていない。
Gooztty側では`parity-verification-20261031-133431-116`が成功し、ビルド・両継承モードの終了コードは0、
`InputsUnchanged=true`、`AutomatedPassed=true`。exe SHA256は
`BF5B863C4D0402ABE8A2113C61403B77FAF6EDFE7B52AD939EC4D9212BC3CF6C`。
`parity-20261031-133748-998.png`、`parity-20261031-133842-838.png`で検索欄・日本語表示を確認した。
同時点の文書の未コミット差分はsource manifestに記録され、検証中は不変だった。

N01は完了とする。#69の間欠不具合はN19で継続し、Issue全体は完了扱いにしない。
## N03完了記録

### ツールと実行結果

所有者の許可を受け、[Zig公式配布一覧](https://ziglang.org/download/index.json)から
`zig-x86_64-windows-0.17.0.zip`を取得した。SHA256
`b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428`は公式値と一致し、
展開先`zig-out/toolchains/zig-x86_64-windows-0.17.0/zig.exe`の`version`は`0.17.0`。
システムのPATHとZig 0.16.0は変更していない。

| 対象 | 実行 | 結果・ログ（`zig-out/`配下） |
|---|---|---|
| 現Gooztty、Zig 0.16.0 | `build --help -Dapp-runtime=none -Demit-exe=false` | exit 0、`ReleaseFast`確認。`n03-zig016-isolated-build-help.log` |
| 固定A/B/C、Zig 0.17.0 | 同上 | すべてexit 0、`fast`確認。`n03-{a,b,c}-isolated-build-help.log` |
| 依存差分16件 | `zig fetch <固定URL>` | すべてexit 0、出力package hashは定義と一致。`n03-dependency-audit/results.json` |

既存の共有キャッシュではA/B/Cのhelpがhash不一致で失敗した。libxevではキャッシュtar内に
package名/元リポジトリ名の二重階層があり、配布元から取り直したアーカイブは元リポジトリ名の一階層だった。
取得し直したlibxevのpackage hashは定義と一致した。原因となったキャッシュの作成経緯は未特定。
キャッシュ削除や依存hashの変更はせず、`ZIG_GLOBAL_CACHE_DIR`を`zig-out/n03-clean-cache`、
0.17の`ZIG_LOCAL_PKG_DIR`を`zig-out/n03-clean-pkg-{a,b,c}`に分けると全helpが成功した。
0.16のhelpもグローバルキャッシュ分離で成功したが、0.16は`ZIG_LOCAL_PKG_DIR`に対応せず、
実際の展開先は作業ツリーの`zig-pkg`だった（N04で`zig env`と生成先を追加確認）。
今後の移行も検証用キャッシュを分離する。既存キャッシュの修復済みとは扱わない。
Zig 0.17の`build`は`--global-cache-dir`を拒否したため、上記の環境変数を使う。
これらの変数は実行プロセス内だけに設定した。失敗ログも`n03-*-build-help.log`に保持する。

これはビルド設定のコンパイル・依存解決の確認であり、Win32/D3D11の0.17移行成功ではない。
固定upstreamにはこのフォークのWin32実装がないため、helpでは`app-runtime=none`を指定した。
移行後のWindowsアプリではこの指定と`emit-exe=false`を外す。

### 段階別の実行手順

各ブランチの作業場所で、N04はZig 0.16.0、N05/N15/N16は取得済み0.17.0の絶対パスを使う。
以下は移行後に実行する手順であり、この事前確認ではWindowsアプリの0.17ビルドは実行していない。

```powershell
# 作業ごとに未使用のディレクトリ名を指定する。既存成果物を消して再利用しない。
$env:ZIG_GLOBAL_CACHE_DIR = '<検証用キャッシュの絶対パス>'
# ZIG_LOCAL_PKG_DIRの指定はZig 0.17のみ。0.16は各作業ツリーのzig-pkgを記録する。
# N04: Zig 0.16.0
zig build --prefix '<未使用の出力先>' -Dcpu=baseline -Demit-docs=false -Doptimize=ReleaseFast --summary all
# N05/N15/N16: Zig 0.17.0
& '<Zig 0.17.0のzig.exe>' build --prefix '<未使用の出力先>' -Dcpu=baseline -Demit-docs=false -Doptimize=fast --summary all
```

版の上書きはしない。A/B/Cのzon値は上表に固定する。配布用`build-release.ps1`はN17以降の
Goozttyで`version.txt`の数値部・連番を確定してから使う。Windows側の`version.txt`は変更しない。
GUI・IME・GPU・終了処理と最終候補の受入条件は計画第5節を維持する。

### 依存・ライセンスとWindowsでの利用箇所

固定URL・package hash・元manifestのhashは[依存差分一覧](windows-november-dependencies.json)に保存した。
元manifestのhashとZig package hashは異なる形式なので、同じ値として比較しない。
確認したライセンス本文・hashは`zig-out/n03-dependency-audit/license-evidence.json`と同ディレクトリの補足本文に保存した。

| 依存 | 確認した表記 | Windows経路・留意点 |
|---|---|---|
| translate-c / aro | MIT | C変換のビルドツール。実行時DLLとは分ける |
| libxev | MIT | 共通イベントループ。Windows独自`windows_xev`との境界はN05で確認 |
| vaxis / zigimg | MIT | CLIのTUIとその画像処理依存。Cでzigimgの取得元固定が追加される |
| z2d | MPL-2.0、由来コードの追加表記あり | フォント等の描画。Aのpackageには本文がなく、[固定コミットのLICENSE](https://github.com/vancluever/z2d/blob/f3cf28188dae39946964c81475ff234c008125a6/LICENSE)とCOPYINGを取得して確認。B/Cは両本文を確認 |
| uucode | MIT、Unicode License V3、UTF-8 decoderの許諾文 | 共通Unicode表生成とvaxisへの共有import。packageのLICENSE.mdが参照する追加本文は同梱されておらず、[固定ソースのlicenses](https://github.com/jacobsandlund/uucode/tree/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses)から取得して確認 |
| zf | MIT | CLI検索。SharedDepsからimport |
| iTerm2テーマ | MIT | 配布テーマ。生成archiveには本文がなく、[対応コミットのLICENSE](https://github.com/mbadolato/iTerm2-Color-Schemes/blob/86a776d/LICENSE)を確認 |
| zig_objc / zig_wayland | MIT | Darwin / GTK Wayland経路。Win32アプリの追加実行時依存ではない |
| fontconfig | COPYINGの許諾文 | `font_backend.hasFontconfig()`時のみリンク。URL変更、package hash維持 |
| gobject | 取得archive内にライセンス本文なし | `addGtk`専用。Win32のリンク対象外。GTKを対象に広げる場合は別途確認が必要 |

上表はソースの表記と利用経路の確認であり、配布物の全ライセンス監査ではない。
N17/N18では実際の組込み・同梱範囲を照合し、z2d・uucode・テーマ等で本文が欠けないよう確認する。
現在の`dist/windows/THIRD-PARTY-NOTICES.md`はConPTYの記載のみであり、移行後の全依存を網羅する証拠には使えない。

### Windows固有変更と移行の確認対象

`b58ef1d67`とWindowsの`ac3ad2b6c`のコード・ビルド・スクリプト差分は158ファイル。
[全パスとupstream変更との重なり](windows-november-port-inventory.json)を固定した。46ファイルはA/B/Cでも変更される。
自動マージの競合数とは異なり、意味上の整合確認にも使う。

| 対象 | N05以降で確認すること |
|---|---|
| Win32 runtime、`windows_xev`、`pty`、Termio | 0.17のI/O・allocator・型API、ConPTY生成/解放・非同期完了 |
| D3D11と共通renderer | 共通描画API、Bの画像/RenderState変更、GPU再生成 |
| SharedDeps・Config・GhosttyExe/Resources | 新依存のimport、MSVC対象・リソースコンパイル、ブランド生成 |
| Surface・config・input・CLI/SSH | 上流変更とWindowsの設定/入力/別コンソール制約との整合 |
| PowerShellビルド/検証スクリプト | 最適化列挙値、出力先、exe指定、版整合と通常/hook分離 |

G01〜G04は本書の再現性・実操作・代替候補の手順へ具体化済み。N05以降で実行結果を追加する。
N03の準備・範囲固定は完了とし、Windowsアプリ本体の移行検証はN04完了後のN05から行う。
