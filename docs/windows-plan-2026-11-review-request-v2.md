Goozttyの11月計画第2版を読み取り専用で再レビューしてください。日本語で回答。ファイル・tque・Gitの変更禁止。リポジトリ外やネットワークは参照しない。
対象:
- docs/windows-plan-2026-11.md（現行第2版）
- docs/windows-plan-2026-11-reviewed-v2.md（レビュー対象の保存版）
- docs/windows-plan-2026-11-tque-review-v2.json（現在の登録内容）
- docs/windows-plan-2026-11-review-response-v1.md（前回指摘の評価・対応）
- docs/windows-plan-2026-11-claude-review.md（前回レビュー原文）
- AGENTS.md、docs/windows-roadmap.md第7/9節、docs/windows-handoff.md、docs/version-update-checklist.md。必要なscripts/*.ps1の実コードも参照。
依頼: upstream取り込み内容を踏まえたA/B/Cの段階化、各ブランチへの統合と検証、日程と遅延分岐、必須依存と単なる順番の区別、既知失敗の扱い、最終候補凍結、署名受入の別管理、tqueのID/親/日付/依存/進捗を確認。前回R01〜R11を解消/部分解消/未解消で評価し、新しい具体的問題があれば重大度順に指摘。
検証済みの入力事実（依頼元がGitHubで確認）:
- 現同期元b58ef1d678be2747c830bc1b1e6c0a086afecf9a→A 3d07ef9e28c4af05065b9e2e546b8ac8f9b62df0は57コミット、A→B 83fb95624b0439ee660c2679b43b38c8b63769cdは116、B→C fbed180a5f181915c92a8f2f561903a6e4645b5aは67。合計240。
- Cは1.4.1-dev、minimum Zig 0.17.0。CはVOUCHED名簿のみの変更。直前a0706b79b3d791873177b1fda4b155267769e8c5のTest/Nix成功を確認し、実ジョブtest/test-lib-vt/Windows libghosttyビルドがsuccess。forkのWin32 GUIは未検証。
- fork fukuyori/ghostty #9本文は既存test-windows-soak.ps1 -DurationMinutesによる数時間の反復を要求。単一プロセスの長時間試験は要求されていない。
- tque CLIで19実行タスクすべての親・日付・依存・title・todo/0%を再読込照合済み。empty stringで日付・依存の解除が可能。延期はIDを維持して候補親へ移動。
- 本依頼は計画改訂とレビューのみ。実際の上流取り込み・実装・build・commit・push・公開は未実施。
出力: 最初に全体判定、次に前回R01〜R11の評価、次に重大度順の新規/残存指摘（ID、ファイルと行/作業番号、根拠、影響、具体的修正案）。未確認を事実と断定しない。計画の範囲と無関係な機能追加を要求しない。最後に未検証範囲。読み取り専用レビューだけを行う。
