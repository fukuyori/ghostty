# N16 固定C統合 読み取り専用レビュー

**結論：今回の統合で入ったコードには、確定できる新しい欠陥は見つかりませんでした。** 確定できた問題は検証記録・配布文書の記載ずれ4件だけで、製品の動作には影響しません。

## 確定した指摘（重大度順）

### C16-R1（中）results JSONが未確定のままで、本文とport-logの記載と食い違う
- **場所:** `docs/windows-november-c-results.json:3-6`
- **根拠:**
  - JSONの値は `"Status": "Snapshot checks complete; merge commits pending"`、`AcceptedWindowsSHA: null`、`AcceptedGoozttySHA: null` のままです。
  - 一方、`docs/windows-november-c-migration.md:9,78` は両SHAを確定値として書いています。
  - さらに `.worktrees/windows-nov/docs/windows-port-log.md:13-14` は「最終状態と確定SHAはmigration記録と**結果台帳**で管理」と書いており、参照先のJSONが実態と合っていません。
- **影響:** 機械で読む台帳から確定コミットを辿れません。port-logの参照先も不正確になります。
- **最小修正:** Statusを統合済みにし、`AcceptedWindowsSHA=06d12a298…` を入れる。Goozttyの合格SHAは同じコミットに自分自身のSHAを書けないため、後続コミットで入れるか、「migration.md:78を正とする」と明記する。

### C16-R2（中）release notesの1.4.1-windows.1節の本文が固定Bのまま
- **場所:** `docs/windows-release-notes.md:21-22, 35`
- **根拠:**
  - 見出しは `1.4.1-windows.1` なのに、本文は「Base: upstream 1.4.0 at `83fb95624`, integrated through Windows `33709d14e`」「The preview sequence restarts for 1.4.0」のままです。
  - 参照先も「B migration record」です。
  - 実際の基盤は固定C `fbed180a5`／Windows `06d12a298`／1.4.1-dev です。
- **影響:** 配布系の文書が誤った基盤版とコミットを示します。`dist/windows/version.txt` の `1.4.1-windows.1` とも整合しません。
- **最小修正:** 3行を固定C／`06d12a298`／1.4.1に置き換え、参照先を `windows-november-c-migration.md` にする。

### C16-R3（低）changelogの重複ハッシュと、既知事象の書き漏れ
- **場所:** `docs/windows-changelog.md:17-18, 22-23`、`docs/windows-release-notes.md:26-32`
- **根拠:**
  - 17行で `(\`83fb95624\`, \`33709d14e\`)` と書いた直後の18行に `(\`33709d14e\`)` が重複しており、編集の残骸です。
  - 22-23行は「既知の設定診断assert以外は合格」と書いていますが、results JSONの `KnownFailures`（9行）とmigration.md:35はvalidate-configのpipe出力で起きる `FileTooBig` も挙げています。これはBでも再現しており、今回の回帰ではありません。release notesにも記載がありません。
- **影響:** 既知事象の一覧が文書ごとに違います。
- **最小修正:** 18行の重複を削り、changelogとrelease notesに「stdoutをpipeにしたvalidate-configはFileTooBig（Bから既存・未修正）」を1行足す。

### C16-R4（低）migration.mdの見出しと文の誤り
- **場所:** `docs/windows-november-c-migration.md:58, 77`
- **根拠:**
  - 58行の見出し「段階検証完了（未コミット）」が、9行・78行の「マージ済み」と矛盾します。
  - 77行の「Goozttyの確定マージコミットである。」は主語がなく、何を指すか読み取れません。
- **最小修正:** 見出しを「段階検証結果（検証時は未コミット）」にする。77行は「port-logの変更はWindowsのマージ経由で取り込まれ、root Goozttyでは直接編集していない」など、意味の通る文に直す。

## 重点項目ごとの確認結果（問題なし）

1. **Unicode escape・UTF-8・command・環状buffer・長い設定値**
   - `CommaSplitter.zig:168-196`：桁を足すたびに `>0x10ffff` を検査するので、`usize` は溢れません。0桁はIllegalEscape、途中で終わればUnfinishedEscapeです。Windowsでは引用符の外がskipされますが、引用符内の試験は有効です。
   - `string.zig:69-77`：残りの長さが文字の長さより短ければ拒否するので、途中で切れたUTF-8を範囲外で読むことはありません。
   - `config/command.zig:47-66`：空白だけの値や `direct:`／`shell:` だけの値はValueRequiredになります。前後の空白を除いた後の末尾は空白ではないため、directには必ず1つ以上の引数が残ります。
   - `circ_buf.zig:67-77,117-121,162-182`：容量0では `full=true` になり、`len`・iterator・`resize` の0⇔非0がどちらも安全です。
   - `RepeatableStringMap.zig`：長い値もarenaに複製されるだけで、固定長bufferは使っていません。
2. **DECIC/DECDC/DECBI/DECFIとpending-wrapの再構成**
   - `Terminal.zig:3561-3645`：列の挿入・削除はスクロール領域内の判定とカーソル復元（defer）が対になっています。DECFIは左マージンの列を削除し、DECBI/DECFIはpending wrapを解除します。
   - `stream.zig:2816-2870, 3143-3161`：引数0は1に補正され、引数が2つ以上なら拒否します。
   - `formatter.zig:567-576, 746-795`：`wrap_column` はmodesとscrolling_regionの両方を出力し、カーソルが右マージン以内にあるときだけ設定されます。
3. **tmux**
   - `control.zig:354-376, 443-469, 556-560`：window-closeとsession-window-changedは `parseDecimalId` を使い、過大なIDや末尾の余計な文字を拒否します。
   - `viewer.zig:551`：自分のsessionのイベントだけを処理します。
   - `stream_handler.zig:437-447`：`%exit` を受けた直後の解放は、viewerがnullでも安全です。
4. **`+ssh`**
   - `ssh.zig:613-643`：stderrは常にinherit（認証案内が見える）で、stdoutはignoreです。リモート側のstderrを捨てるのはscriptの非verbose版だけです。
   - `ssh.zig:332-356`：失敗時は `xterm-256color` に戻り、TERMはSetEnvではなくssh自身の環境変数で渡すので、既存の挙動は変わりません。Windows OpenSSHのpasswordやkeyboard-interactiveの入力はコンソールから直接読むため、stdinのpipeとは衝突しない設計です（実機では未確認）。
5. **依存・共有コード・製品名**
   - z2d 0.13.2とzigimgのhashは `docs/windows-november-dependencies.json` と一致します。
   - `src/input/command.zig:710-714` はWindowsのブランド表示を保ち、他OSは上流どおりです。
   - `.github` 配下のVOUCHED.td／test.ymlはworktreeにありません。

## 今回の回帰ではない既存事項（参考）
- **tmuxの残りの通知（既存）：** `control.zig:240,271,311,349,402,433,438,529` の通知（window-add、window-renamed、window-pane-changed、client-session-changedなど）は、今も正規表現 `[0-9]+` で取り出した値を `parseInt … catch unreachable` で変換しています。過大なIDが来ると、安全検査ありのビルドではpanic、ReleaseFastでは未定義動作になります。固定Cが直したのは2種類だけです。
- **validate-configのpipe出力（既存）：** `FileTooBig` は未修正です（#66・#69・#72も未解決のまま）。
- **Windows側の版ファイル（方針どおり）：** Windows側の `dist/windows/version.txt`（`1.3.2-windows.16`）とzonの1.4.1は数値部分が合いません。preflight文書の方針どおりで、配布スクリプトはGoozttyで使う前提です。

## 仮説（確定ではない）
- **pending-wrap再構成の背景色：** 空白セルを復元する経路（`formatter.zig:781`）では、スタイルを復元する前に空白とECHを出力します。そのため、内容の出力後に既定以外の背景色が残っていると、右端のセルにその色が付く可能性があります。試験はしていません。
- **DECDCとpending wrap：** DECDCは `deleteChars` を経由するためpending wrapを解除しません。DECICは `insertBlanks` 経由で解除するので、両者の扱いが違います。xtermと同じかどうかは確認していません。

## 未検証の範囲
- 実際のSSHサーバーでの認証（password、keyboard-interactive、host key確認）と、terminfoをstdinで送っている最中のprompt表示。#72（別コンソールの問題）
- 物理IME、実際のGPU障害、sleep・復帰、最終耐久試験
- 署名付きinstallerとZIPの受入。`version.txt` が `1.4.1-windows.1` の状態での `build-release`／`build-zip`／`build-installer` の実行（検証に使った成果物は統合前の作業ツリーから作ったもので、表示版はgit由来です）
- validate-configのstdoutをpipeにした経路の修正と、その回帰試験
- 確定SHA（`06d12a298`／`281c300ae`）そのものからの再ビルドと再試験。記録上はsnapshotとソースが同じという扱いです。本レビューではgitの差分を直接確認しておらず、確認したのはworktreeとHEAD作業ツリーのファイルだけです。
