N16 固定upstream C（fbed180a5f181915c92a8f2f561903a6e4645b5a、1.4.1-dev）の統合を、日本語で読み取り専用レビューしてください。
編集・コマンド実行・Git/tque変更・外部アクセスは禁止。Read/Grep/Globでリポジトリ内だけを参照し、レビュー結果だけを出力してください。

確定コミット:
Windows 06d12a298958ee97ee3d46b0c7f16658eeca8a21（親 cbf203f9e、固定C fbed180a5f181915c92a8f2f561903a6e4645b5a）。
Gooztty 281c300aee9cbc42f7a5ff08ab62561a113aa3b9（親 899d0de6f、上記Windows）。両方originへpush済み。

主な資料:
- `git show --remerge-diff`相当の解決結果は `.worktrees/windows-nov` の `src/input/command.zig` と `.github`削除。元の競合解決は N16 C commit treeとupstream commitの差を参照。
- `docs/windows-november-c-migration.md`、`windows-november-c-results.json`、`windows-november-c-lifecycle-comparison.json`
- `docs/windows-november-c-migration.md`に記載したsource.json、testログ参照
- `src/cli/CommaSplitter.zig`, `src/config/command.zig`, `src/config/string.zig`, `src/config/Config.zig`, `src/config/RepeatableStringMap.zig`, `src/datastruct/circ_buf.zig`, `src/terminal/Terminal.zig`, `src/terminal/formatter.zig`, `src/terminal/stream.zig`, `src/terminal/tmux/control.zig`, `src/terminal/tmux/viewer.zig`, `src/termio/stream_handler.zig`, `src/cli/ssh.zig`
- `.worktrees/windows-nov/docs/windows-port-log.md`

重点:
1. Unicode escapeのhex桁、UTF-8境界、空command/連続空白、環状buffer 0容量、設定長値の安全性。
2. DECIC/DECDC/DECBI/DECFIと右端pending-wrap formatter再構成の状態・margin境界。
3. tmux window-close/active-window/exitイベントのID検査、セッション分離、所有権解放。
4. Windows `+ssh` terminfo導入中の認証案内stderr可視性、stdinにterminfoを送る時のprompt安全性、失敗時TERM fallback。SetEnv/TERMの既存挙動と混同しない。
5. 新しいz2d/zigimg固定依存、Windows共有コードへの変更、製品名差分。
6. 検証記録の正確さと限定。

確認済みとして記録された範囲:
両snapshotでDebug/fast/hook 145/145、全Zig main 4244成功/67 skip、Win32 normal/hook main 196成功/1 skip、GUI/parity、controlled GPU/power、lifecycle各37/37と4枚確認。resourceのmanifest/icon/terminfo/versionは各3成果物で確認。設定diagnosticsは各7/8で同一の既知wrong-owner assert。validate-config stdout pipeのFileTooBigはCとBで観測、正規ファイル出力テストは合格。SSH用fake helper 8条件（verbose/nonverbose×installer success/failure×製品）とTERM fallback、stderr案内を確認。実SSH認証/物理IME/実GPU fault/sleep/最終耐久/署名パッケージ受入は未実施。

指摘は新しく確定できる欠陥だけを重大度順に。ID・ファイル行・根拠・影響・最小修正を示す。仮説・改善案を確定不具合に混ぜない。既知の未修正項目を今回の回帰と誤認しない。問題がなければ明記し、最後に未検証範囲を列記してください。
