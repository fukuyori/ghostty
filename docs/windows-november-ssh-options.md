# N07: Windows +ssh方式の比較（2026-10-31）

検討を完了し、方式決定は未了として記録する。N08の実装は開始しない。#72はOPENのまま。
計画のN07完了条件は「所有者の決定または未決定事項の記録」であり、方式の採用や不具合修正ではない。

## 確認した事実

- [#72](https://github.com/fukuyori/ghostty/issues/72)には、Gooztty内のPowerShellから`+ssh`を実行すると別のWindows Terminal窓へ接続したという所有者の実測がある。今回その接続先へ再接続はしていない。
- `src/build/GhosttyExe.zig:47`はWindowsアプリをGUI subsystemで構築する。`src/cli/ssh.zig`のchildExecはstdin/stdout/stderrをinheritにしてspawnし、子の終了を待つ。src内にAttachConsole/AllocConsoleの呼出しはない。
- Microsoftは、GUIプロセスは作成時にconsoleへattachされず、AttachConsoleで親consoleへ接続できると説明している。標準ハンドルには親の継承方法による例外がある。[AttachConsole](https://learn.microsoft.com/en-us/windows/console/attachconsole)、[Creation of a Console](https://learn.microsoft.com/en-us/windows/console/creation-of-a-console)。
- BのSSH変更はTERMを子の環境へ渡してユーザーのSetEnvを保持する変更であり、console接続処理は追加していない。外部接続しないprobeによる6条件の成功は引数と環境の検証であり、同一paneの対話入出力の検証ではない。

※推測です: GUI subsystemとconsole未接続が#72の別窓起動に関係すると考えられるが、親/子のconsole所属と標準ハンドルを実SSH起動時に採取していないため、唯一の原因とは断定しない。

## 選択肢

| 案 | 変更と利用方法 | 長所 | 残る検証・負担 |
|---|---|---|---|
| 1. 親consoleへattach | +sshなどCLI actionに限り親consoleへ接続。パイプ/リダイレクト済み標準ハンドルを壊さない | 配布実行ファイルを増やさず、既存コマンドを維持できる | 親shellの待機/入力競合、Ctrl+C、EOF、パイプ、親consoleなし、既attach時の処理を検証。AttachConsoleだけで親shellを待機させられるとは扱わない |
| 2. console subsystemのCLI入口 | CLI用実行ファイルで共有CLI処理を直接実行し、sshへstdio/終了コードを受け渡す | GUI起動とCLIの対話契約を分けられ、shellから扱いやすい構成を目指せる | 入口名・CLI対象範囲・共有コード・ブランド・インストーラー/ZIP・署名・PATH・shell integrationを更新。GUI exeを起動するだけの薄いラッパーではconsole問題の解決を保証できない |
| 3. 制約文書化 | Windows内ではplain sshを使い、+sshの別窓起動を既知制約とする | 実装・配布変更を抑え、移行作業と分離できる | #72の同一pane対応は未解決。plain sshでは+sshのterminfo自動設定を利用しないため、必要なリモート設定を別途案内する |

ロクの提案は、恒久対応を行うなら案2を第一候補として小さな試作で確かめ、今月は対応を延期するなら案3を明記すること。
これは提案であり採用決定ではない。案1も親shellとの入力・待機を実測できれば候補に残す。

案3を選ぶ場合、Bash等ですでにssh function/aliasが+sshへ転送する構成では、それを迂回してネイティブsshを呼ぶ手順も必要。現在のPowerShell利用と他shellの設定を混同しない。

## 所有者の決定が必要な事項

1. 同一paneでの+sshを今月実装するか、既知制約として延期するか。
2. 実装する場合、追加のconsole実行ファイルを許容するか。名前や+ssh以外のCLI対象範囲は選択後に具体化する。
3. 接続確認に使用するSSH環境と、認証/対話入力の実機受入条件。既存Issueの接続先への無断接続はしない。

N08の着手条件は所有者の方式決定とN16完了。N07を完了しても、この条件は解除しない。

## 実装前に必要な検証

PowerShell/cmdから通常起動、パイプ/リダイレクト、Ctrl+C、認証入力、ウィンドウリサイズ、終了コード、親なし起動を比較する。
console所属PIDと各標準ハンドルをログに取り、現在の実装、案1または2、plain sshの差を示す。
検証用ヘルパーと配布するCLI入口は区別し、パッケージ/署名の受入はN17/N18で行う。

