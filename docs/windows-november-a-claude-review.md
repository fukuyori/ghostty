# N05 読み取り専用レビュー（固定 upstream A / Zig 0.17 移行）

## 全体判定

**修正が必要な欠陥は見つかりませんでした。** Windows のマージ c6669ed65 と Gooztty のマージ f2b98c662 は、このままで問題ないと判断します。

指定された重点項目は、すべて根拠のコードを確認して問題なしとしました。確認の過程で、欠陥ではない注記が2件ありました（後述の I-1、I-2）。

## 重点項目の確認結果

| 項目 | 結果 | 根拠 |
|---|---|---|
| 同期 I/O 取消 | 問題なし | `src/termio/Exec.zig:261-298`。CancelSynchronousIo、CancelIoEx、10ms 待機を繰り返した後に join しています。読み取りスレッドは `.check_quit` で quit パイプを確認し（`Exec.zig:1866-1903`）、EOF と異常系は `return` で抜けるので、取消を待つ側が止まることもありません。移行差分は `builtin.target.os.tag` への置換だけで、ロジックは変わっていません。 |
| OSC7 | 問題なし | `src/termio/stream_handler.zig:1553-1570`。PowerShell 統合（`ghostty-integration.ps1:13`）が送るのは `System.Uri.AbsoluteUri`、つまり `file:///C:/...` です。0.17 の `std.Uri.parseAfterScheme` は空の authority で host を null のままにします（`lib/std/Uri.zig:188-190`）。そのため `HostName.fromUri` は `UriMissingHost` を返し（`HostName.zig:36`）、Windows 用の分岐に入ります。空文字列を拒否する `validate`（`HostName.zig:51`）には到達しません。新しく増えた `NameTooLong` と `InvalidHostName` も網羅されています。 |
| SSH | 問題なし | Windows では ControlMaster を使わない処理と、リモートコマンドがある場合の terminfo 省略（#71）がそのまま残っています。変更は API の置換だけです（`allocPrint`→`alloc.print`、`@intFromEnum`→`@backingInt`）。 |
| D3D11 行列 ABI | 問題なし | `math.Mat` は `[4]@Vector(4, f32)` です（`src/math.zig:2-3`）。これを `[4][4]f32` へ `@bitCast` してもメモリ配置は変わりません。`generic.zig:2429` と、試験 fixture の `App.zig:692` が同じ変換を使っています。上流の OpenGL（`opengl/shaders.zig:166`）と Metal（`metal/shaders.zig:201`）も同じ型です。HLSL は `column_major` で、サイズとオフセットの検査（144 / 96 / 132、`d3d11/shaders.zig:201-203`）も残っています。 |
| reflection（型情報） | 問題なし | `Pipeline.zig` の `inputElements` は `field_names` と `field_types` を同時に回していて、`@offsetOf` に渡す名前と型の対応は崩れていません。 |
| allocator / sentinel | 問題なし | 置換は `dupeZ`→`dupeSentinel(.., 0)`、`bufPrintZ`→`printSentinel(.., 0)`、`stackFallback`→`BufferFirstAllocator` で、意味は変わっていません。OSC7 では一時領域の `defer arena_alloc.deinit()` の順序も以前と同じです。範囲チェック付きの `@fromBackingInt(@intCast(lparam))`（`LifecycleTestHooks.zig:126-127`）も安全です。 |
| ビルドの依存・資源 | 問題なし | rc ファイルが埋め込むのは `ghostty.manifest` と `ghostty.ico` の2つだけで（`dist/windows/ghostty.rc:16,19`）、その両方の内容が依存として登録され、ハッシュにも入っています。0.17 の `findProgram` は絶対パスの名前を受け付けます（`lib/std/Build.zig:1628-1629`）。 |
| 最適化指定のスクリプト | 問題なし | `scripts/` に残っている最適化指定は `-Doptimize=fast` だけです。検査はすべて `IsDebug` で行っていて、`--version` に出る `build mode` の文字列を比べているスクリプトはありません。 |
| OpenGL の `Device.init` | 問題なし | Windows でフィールド未定義の device を返しても、`OpenGL.zig` の init、deinit、threadEnter、threadExit はいずれも Windows では `display` と `config` を読む前に戻ります（`OpenGL.zig:60,106,219,233`）。 |
| 上流機能の損失 | 見当たらない | Windows と上流の差分にある src/build の変更（pkg-config、xcframework、GhosttyZig など）は、Windows 側に固有の差分がなく、上流 A と同一です。上流 A の `dupeSentinel(u8, argv0), 0)` は引数の位置を誤っていますが、Windows 側では正しく直してあります（差分 40556-40562 行）。 |
| Gooztty の製品差分 | 問題なし | 差分は `AGENTS.md` と `src/brand.zig` の2ファイルだけで、どちらもブランチ固有の文面と値のみです。AGENTS は WASM の例の `small` だけを取り込み、どちらの AGENTS にも `ReleaseFast` は残っていません。 |

## 注記（欠陥ではない）

### I-1 Windows の tic を探す順序が変わった
- **場所:** `src/build/GhosttyResources.zig:65-71`
- **内容:** 0.17 では Git、MSYS2、Cygwin の絶対パスを先に調べ、その後で PATH 上の `tic` を探します。
- **影響:** 開発環境の PATH に別の tic があっても、Git 同梱の tic が優先されます。出力される terminfo の配置は検証済みなので、今回の配布物への影響はありません。
- 0.16 では PATH を先に探していた、と推測しています。0.16 の std は読んでいないので、この点は未確認です。
- 修正は必要ありません。PATH の tic を優先したい方針であれば、`"tic"` をリストの先頭に移せば済みます。

### I-2 Windows ビルドでは configure cache が常に無効になる
- **根拠:** `findProgram` は呼ばれるたびに `graph.poisonCache()` を実行します（`lib/std/Build.zig:1625`）。上の tic 検索は Windows ビルドで毎回実行されます。
- **影響:** icon、manifest、ConPTY のために登録した configure 依存（`WindowsVersionResource.zig:31`、`build.zig` の `installConPty`）は、現状ではキャッシュが効くことにつながっていません。毎回 configure をやり直すので、正しさは損なわれていません。リソースコンパイラの再ビルドは、ヘッダーに入れたハッシュで別に保証されています。
- 修正は必要ありません。ただし `docs/windows-november-a-migration.md:21` の「configure cache の依存を登録した」は、「登録はしたが、現状ではキャッシュは効かない」と読める書き方にしておくと誤解を防げます。

## 未検証の範囲（このレビューで確認していない事項）

- **Gooztty の確定 SHA f2b98c662 での再ビルドと再試験:** `zig-out/n05-committed-validation.json` には Windows の c6669ed65 の結果だけが入っています（ビルド・試験とも終了コード 0、通常版 fast の hash `633237C3…`）。Gooztty の確定 SHA の結果はまだありません。
- **Windows c6669ed65 の Win32 試験、GUI、parity:** 確定 SHA での結果は JSON に含まれていません。なお hash が事前の `AF7F…` と違うのは、版文字列が `+ac3ad2b6c` から `+c6669ed65` に変わったためと考えられます。※推測です。
- **ホスト名付き OSC7:** `file://<コンピュータ名>/C:/...` の形式は扱っていません。0.17 の `validate` は `_` を含むホスト名を拒否します（`HostName.zig:77-78`）。ただしこれは上流と同じ挙動で、PowerShell 統合はこの形式を送らないため、今回の移行による退行ではありません。
- **実機での受入（N06 予定）:** 物理キーと物理 IME、実際の GPU 障害、実際の sleep 復帰。
- **既知の失敗と間欠事象:** 設定診断の `OwnerCloseWithOtherWindow`（N02 で追跡中）、#69 の間欠失敗。
- **非 Windows ターゲット:** 方針どおり確認していません。
