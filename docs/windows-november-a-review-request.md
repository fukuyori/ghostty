N05 固定upstream A / Zig 0.17移行の実装を、日本語で読み取り専用レビューしてください。
ファイル編集・コマンド実行・Git/tque操作・外部アクセスは禁止。Read/Grep/Globでリポジトリ内だけを読んでください。レビュー結果だけを出力してください。
確定したマージコミット:
Windows c6669ed65a74029f8d22799ab7fee77a7764ac12（親 ac3ad2b6c と固定A 3d07ef9e28c4af05065b9e2e546b8ac8f9b62df0）。
Gooztty f2b98c662f677c6f23a900a8cb3f8df6aaf116b4（親07be8fc21と上記Windows）。pushなし。
rootはGooztty、.worktrees/windows-novがWindows。既存の編集中文書はコミット外で保持。AGENTSは枝別テキストを維持しsmall指定のみ統合。
読む資料:
- zig-out/n05-review-port-migration.diff（今回のWindows移行差分）
- zig-out/n05-review-windows-vs-upstream.diff（上流AとWindowsの差。既存port実装も含むため新規欠陥と混同しない）
- zig-out/n05-review-gooztty.diff（製品差分）
- docs/windows-november-a-migration.md、docs/windows-plan-2026-11.md、.worktrees/windows-nov/docs/windows-port-log.md
- 必要な関連ソース。特に衝突解決、同期I/O取消、OSC7、SSH、D3D11行列ABI、reflection、allocator/sentinel、ビルドの依存/資源、最適化スクリプト、OpenGL Device.init。
検証済み: 両製品Debug/fast/hook、全Zigテスト、Win32両variant、GUI画像、parity両設定、制御GPU/復帰、IME自動。設定診断はN04同様OwnerCloseWithOtherWindowの1件が既知失敗でN02追跡。物理IME 0.17と実GPU障害/sleepは未受入、N06予定。OpenGLの追加修正後も既定D3D11通常版hashは不変。
マージ後のソースは検証済みGoozttyスナップショットと一致。現在確定SHAで追加ビルド/Win32試験中で、zig-out/n05-committed-validation.jsonがあれば結果を参照できます。文書内の「コミット待ち」は更新作業中であり、陳腐化表現だけは欠陥扱いしない。
主眼: 具体的な回帰、未処理の0.17 API差、メモリ安全性、上流機能損失、検証によって隠れた不整合。以前からの既知制約や後続受入を新しい欠陥と混同しない。推測は明記し根拠コードを示す。指摘を作るためだけの提案は禁止。
出力: 全体判定、問題は重大度順でID/ファイル行/根拠/影響/最小修正案、未検証範囲。問題がなければ明記。
