N15 固定upstream B（1.4.0）の統合を、日本語で読み取り専用レビューしてください。
編集・コマンド実行・Git/tque変更・外部アクセスは禁止。Read/Grep/Globでリポジトリ内だけを参照し、レビュー結果だけを出力してください。

確定コミット:
Windows 33709d14e98d591680cf6628f97e9ef99d7a16c9（親 c6669ed65 と固定B 83fb95624b0439ee660c2679b43b38c8b63769cd）。
Gooztty d9cbeef564d5df3cc7fefd947e451d7c71bad650（親 f2b98c662 と上記Windows）。
rootはGooztty、.worktrees/windows-novはWindows。既存の編集中文書はコミット外で保持しています。

資料（大きいdiffはGrepで絞り、必要範囲をRead）:
- zig-out/n15-review-resolution.diff: Windowsマージのremerge-diff。競合解決の重点資料。CI削除部分も含む。
- zig-out/n15-review-windows.diff: AからBへの全変更。上流由来の変更も含む。
- zig-out/n15-review-product.diff: WindowsとGoozttyの差。従来のブランド/文書差を新規欠陥と混同しない。
- docs/windows-november-b-migration.md、windows-november-b-results.json、windows-november-b-committed-results.json、windows-november-b-lifecycle-comparison.json
- docs/windows-november-p0-investigation.md、docs/windows-november-ssh-options.md、docs/windows-plan-2026-11.md
- src/Surface.zig、src/renderer/generic.zig、src/terminal/modes.zig、および必要な関連ソース
- .worktrees/windows-nov/docs/windows-port-log.md

重点:
1. SurfaceのenvスコープとExec.init失敗時の所有権・二重解放。
2. animationTickの位置、Kitty RenderState/配置世代判定、force_image_rebuildとGPU復帰、画像寿命。
3. Win32入力9001維持とKitty clipboard mode5522のWindowsアプリ限定無効化、lib/他OSの挙動。
4. SSH/SetEnv、shell integration、Windows依存/リソース、ブランドと版番号の整合。
5. N15の検証/合格判定が証拠と一致するか。未検証事項を検証済みと誤記していないか。

確認済み:
両snapshotでDebug/fast/hook、全Zig主4211成功65skip、Win32通常/hook主196成功1skip、GUI/parity、制御GPU/電源復帰、lifecycle各37/37と4画像確認。追加Kitty画像/アニメーション/GPU復帰、ローカルSSH引数/TERM6条件、Bash cwd制御文字チェック。
設定診断は各7/8でOwnerCloseWithOtherWindowが既知失敗。P0で試験が非所有者を閉じることを確認し、実所有者を閉じる検証器では成功。正式試験の修正は未適用。手動タスクバー×はダイアログへ誘導され閉鎖条件を満たさずタイムアウト。この失敗を合格扱いしない。
#69は8回の固定A再実行で未再現、未解決。#72は方式比較だけ完了、選択/実装は未着手。
マージ後はソース同等性（16ファイルCRLF/LF差のみ）を確認し、確定SHAで通常fastビルド145/145、Win32主196成功1skip、CLI/FileVersion照合も両製品成功。
配布用version.txtは採番規則で1.4.0-windows.1に整合。直接ビルドはGit由来の版（1.4.0-windows+33709d14e / 1.4.0-gooztty+d9cbeef56）。署名配布物の検証ではない。
実IME/実GPU障害/sleep/実SSH認証/最終耐久/署名配布受入は後続段階。Bでは物理IMEの再受入を主張しない。
文書の「マージ待ち」は前段階の履歴が残っており、末尾に確定記録があります。履歴表現のみを新規欠陥として扱わない。

出力: 全体判定、指摘は重大度順にID・ファイル行・根拠・影響・最小修正案。確定欠陥と仮説/改善案を区別。指摘を作るための提案は禁止。問題がなければ明記。最後に未検証範囲を記載。
