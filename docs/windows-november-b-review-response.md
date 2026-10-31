# 固定Bレビューへの対応（2026-10-31）

対象: [Claude Codeレビュー](windows-november-b-claude-review.md)。コード上の確定欠陥は指摘されていない。今回は文書のみを修正した。

| ID | 対応 |
|---|---|
| L-1 | 計画§6をブランチ規則に合わせ、中間マージでもversion.txtの数値ベースを整合させると明記。Bの1.4.0-windows.1は開発段階の値で、配布候補はN17で確定する。changelog/release notesの見出しと説明もdevelopment stageへ変更した。公開状況は従来どおりGitHub Releasesを参照する。 |
| L-2 | Windows側のport-logでpending表記を除き、Windows 33709d14e / Gooztty d9cbeefとGooztty側の確定台帳を明記。事前検証と確定コミットの追加照合を区別した。 |
| I-1 | 移行記録に、設定診断スクリプトはexit 1、各ケースのアプリはexit 0と明記。トップレベルFailure=nullはドライバー完走を示し、全試験合格を意味しないと補足した。 |
| I-2 | 確定コミットの検証時に文書変更が残っていた点を制約として明記した。過去の実行時点のsource hashやclean判定を後付けで記録していない。N17では計画どおりクリーンな専用worktreeと入力hashを使用する。 |

## 確定コミットの追加照合の証拠範囲

`windows-november-b-committed-results.json`はSHA、ビルド/テストのログ、成果物hash、版を記録するが、実行時点の全入力hashとGit statusは収録していない。
実行前に行ったsnapshotとの照合結果は`zig-out/n15-actual-merge-source-comparison.json`に保存され、対象はsrc/pkg/scripts/buildで、16件の改行差は正規化後に一致した。
これをクリーンな作業ツリーでの配布候補検証と同一視しない。N17の入力固定と最終受入は未実施である。

## 反映先と確認

port-logの修正先は`.worktrees/windows-nov/docs/windows-port-log.md`のみ。Gooztty側の同ファイルはブランチ規則に従って直接編集していない。port-log修正をWindows `cbf203f9e`でコミットし、Gooztty `76ecf61d4`でマージした。Gooztty側の計画・版説明・検証記録の修正はレビュー対応文書とともに保存する。

既存の文書変更を保持し、変更箇所の差分・参照先・版番号と確定SHAを確認した。製品コード変更はなく、ビルドやGUI試験の再実行は行っていない。
