## 全体判定

**合格。N15の競合解消に、確定した欠陥は見つかりませんでした。**
Surface、Kitty描画、modes の3件の競合解消は意図どおりで、上流Bの変更とWindows固有の保持事項を両立しています。検証記録も、提示された合格内容と台帳/ログが一致しています。残る指摘は文書の整合性に関する軽微なもの2件だけです。

---

## 重点項目の確認結果（指摘なし）

**1. Surfaceのenvスコープ／Exec.init失敗時の所有権**
- `src/Surface.zig:668-687`: ブランド変数の除去（`brand.env_prefix ++ "LOG"`、Windowsの`removeOldTerminalVars`）と`SURFACE_ID`の設定は、`termio_env`ブロックの中で行われています。そのブロック内の`errdefer env.deinit()`（674行）は、ブロック外の`Exec.init`まで届きません。
- `src/termio/Exec.zig:101-102`と`Exec.zig:702-703`: `Subprocess.init`は`cfg.env`を受け取り、失敗時は自分で`env.deinit()`します。Surface側に解放処理が残っていないため、二重解放は起きません。
- `removeOldTerminalVars`の戻り値は`void`（`src/brand_env.zig:40`）なので、新しい失敗経路は増えていません。
- `Termio.init`はbackendを失敗時に解放しません（`src/termio/Termio.zig:309`付近）。そのためSurface側の`errdefer io_exec.deinit()`（703行）は正しく、上流と同じ構成です。

**2. animationTick／Kittyの世代判定／GPU復帰**
- `animationTick`の呼び出しは1か所だけです（`src/renderer/generic.zig:1559-1578`）。位置は`terminal_state.beginUpdate`（1585行）の前で、二重のtickはありません。
- 1613行の判定は`force_image_rebuild or kittyRequiresUpdate(state.terminal, &self.terminal_state)`です。更新後は`force_image_rebuild = false`と`images_rebuilt = true`が両方設定されます（1626-1627行）。
- GPU復帰（1302-1356行）は`draw_mutex`を取得したうえで、`images`/`terminal_state`を`.empty`にしてから`force_image_rebuild = true`を立てます。リセット後は世代値が0になりますが、強制フラグがあるので再構築の取りこぼしはありません。synchronized outputでの早期return時やOOM時もフラグは残るため、次のフレームで再構築されます。
- 古い画像（GPUリソース）は、ロック中に`images.deinit`で解放されます。描画判定には`images_rebuilt`と`swap_chain_rebuilt`の両方が含まれています（1905-1923行）。

**3. 9001の維持／5522の無効化**
- `src/terminal/modes.zig:413-422`: 5522は`artifact != .lib and os == .windows`の場合だけ無効です。挙動は次のとおりです。
  - Windowsアプリ: 無効（DECSETは無視され、DECRQMは未認識を返す）
  - macOS・GTKアプリ、全OSのlib-vt: 有効（上流Bと同じ）
- 9001は維持されています。A→Bの差分ではコメントと条件式が変わっただけです（windows diff 15228-15237行）。
- `stream_terminal.zig:7721`のlib限定スキップはAから変わっておらず、上流と同じです。
- snapshot形式のbit 43（`win32_input`）もAから変更なしで、アプリ側ではsnapshotの復元に使われていません。

**4. SSH／shell integration／依存／ブランド**
- `+ssh`は、`-o SetEnv=TERM`をやめて子プロセスの環境で`TERM`を渡す方式に変わりました。これは上流のとおりに取り込まれています。probeの6条件（ユーザーの`SetEnv=EDITOR=vim`を保持、`TERM`の値）は、`windows-november-b-results.json`の記録と一致しています。
- Bashとzshの制御文字除去は上流どおりです。
- z2d 0.13.0とthemes 20261019は`docs/windows-november-dependencies.json`の固定値と一致しています。
- 製品差分のコードは`src/brand.zig`だけで、従来のブランド差です。

**5. 検証記録の整合**
- `zig-out/n15-committed-*-{build,test}.log`には145/145工程、196/197成功・1スキップが両製品分記録されており、`committed-results.json`のSHA、版、exit 0と一致しています。
- lifecycleの比較記録は74件すべて`Passed: true`（37件×2製品）です。
- 設定診断の段階exit 1は、失敗として残したまま記録されています。

---

## 指摘（重大度順）

### L-1【確定・文書の不整合／軽微】中間段階での配布版採番が計画§6と食い違っている
- **場所:**
  - 計画側: `docs/windows-plan-2026-11.md:167-170`。Cの数値ベースは1.4.1、「goozttyの中間検証も同じ方式で、各段階の配布版を採番しない」、NはN17で確定、と書かれています。
  - 実際の変更: `dist/windows/version.txt`が`1.4.0-windows.1`になり、`docs/windows-changelog.md:10`と`docs/windows-release-notes.md:15`に`## 1.4.0-windows.1`の節が追加されています（release notes 18行には「The preview sequence restarts for 1.4.0」とあります）。
- **根拠:** チェックリストはversion.txtの数値部分を`build.zig.zon`（1.4.0）と一致させることを求めているので、版を合わせること自体には理由があります。しかし計画§6は更新されておらず、release notesは「release history」の一項目として、配布されない可能性が高い版を記載しています（Cで1.4.1になる予定のため）。
- **影響:** 未公開の版が公開済みの版と同じ形式で記録されるため、N17で版を確定するときや月末報告で混乱しやすくなります。製品の動作には影響しません。
- **最小修正案:** 計画§6に「Bで1.4.0-windows.1へ整合済み（未配布）」と追記します。または、changelogとrelease notesの該当節の見出しに「unreleased / development stage」と明記します。

### L-2【確定・文書／軽微】Windows port-logのB項目に確定記録がない
- **場所:** `.worktrees/windows-nov/docs/windows-port-log.md:8-12, 43-47`。同じ内容がGoozttyにも無変更で取り込まれています。
- **根拠:** マージコミット`33709d14e`に含まれている項目の見出しが「pending commit」で、本文も「No merge commit has been made for this stage」「accepted SHAs remain pending」のままです。port-logの中に確定記録はありません。A項目（55行付近）は「performed before the merge commit; the final commit ledger is maintained on Gooztty」と、どこを参照すればよいかを示していましたが、B項目にはそれがありません。
- **影響:** port-logだけを読むと、Bがまだ未マージに見えます。ご指摘のとおり、移行記録には末尾に確定記録があるので、問題はport-logだけで完結していない点に限られます。
- **最小修正案:** 次にWindowsで更新するとき、B項目に「確定SHA 33709d14e、確定時の台帳はGoozttyの`windows-november-b-migration.md`を参照」の1行を追加します。

### 改善案（欠陥ではありません）
- **I-1:** `windows-november-b-migration.md:43, 79`の「exit 0」は製品プロセスの終了コードのことです。一方、台帳では`config-diagnostics`の段階が`ExitCode: 1`で、トップレベルは`"Failure": null`になっています（`windows-november-b-results.json:221, 257`）。誤読を防ぐため、「スクリプトはexit 1、各ケースのアプリはexit 0」と書き分けると明確になります。
- **I-2（仮説）:** 確定SHAのGooztty検証は、未コミットの文書変更（AGENTS.md、docs/）が残るroot作業ツリーで行われています。版表示にdirtyの印は付きません。文書はビルドの入力ではないと考えられますが、`committed-results.json`にはsource hashや作業ツリーがcleanかどうかの記録がありません。

---

## 未検証範囲（今回のレビュー対象外、または証拠がない）
- 実行時の挙動全般。今回は読み取りのみで、ビルド・テスト・GUIの再実行はしていません。結果は既存のログとJSONで照合しました。
- 物理IME、実際のGPU障害/sleep、実SSHサーバーでの認証。Windows版OpenSSHが環境変数の`TERM`を実際にサーバーへ送るかどうかは、probeでは確認できず未検証です。
- zshの実行環境での受け入れ確認、最終耐久試験、署名済み配布物（`build-release.ps1`/インストーラー/ZIP）の受け入れ。
- 設定診断`OwnerCloseWithOtherWindow`の試験修正（#66）、#69の間欠事象、#72の方式選択と実装。いずれも未解決です。
- CIの削除部分は、フォークの方針どおり削除を維持していることだけを確認しました。上流CIの内容は精査していません。
- `windows-november-p0-investigation.md`と、Kittyの検証で保存された画像そのものは開いていません。
