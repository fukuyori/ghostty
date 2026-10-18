# Windows での設定の対応状況

この文書は [Configuration Support on Windows](windows-config-support.md) の
日本語版です。内容が異なる場合は英語版が正です。

upstream の Ghostty の全設定項目(`src/config/Config.zig`)について、
`1.3.2-windows.16` 時点のネイティブ Windows ビルドでの対応状況をまとめています。
項目は upstream のリファレンスと同じ順に並べています。設定ファイルの場所と
Windows 固有の動作は[ユーザーガイド](windows.md)(英語)を参照してください。

◎ は、その設定またはそれが制御する機能を実際に動かして確認した記録が
[port log](windows-port-log.md) か [roadmap](windows-roadmap.md) にあるものです。
備考に記録の場所を書いています。○ はコードを読んで判断したもので、その設定を
処理するコードは Windows で動きますが、動作確認の記録はありません。△ と ✕ も、
備考に確認記録を挙げていない限り、コードからの判断です。

| 設定項目 | 分類 | 状態 | 備考 |
|---|---|---|---|
| `language` | GTK | - | GTK 専用。Windows の UI はこの設定では翻訳されない。 |
| `font-family` | フォント | ◎ | ファミリー名で照合する(フルネームやスタイル名ではない)。`+list-fonts` で確認できる。確認記録: roadmap #1/#2(2026-09-28)。 |
| `font-family-bold` | フォント | ○ |  |
| `font-family-italic` | フォント | ○ |  |
| `font-family-bold-italic` | フォント | ○ |  |
| `font-style` | フォント | ○ | 明示したスタイル名は完全一致で照合し、見つからない場合は合成スタイルになる。 |
| `font-style-bold` | フォント | ○ |  |
| `font-style-italic` | フォント | ○ |  |
| `font-style-bold-italic` | フォント | ○ |  |
| `font-synthetic-style` | フォント | ○ |  |
| `font-feature` | フォント | ○ |  |
| `font-size` | フォント | ◎ | 確認記録: roadmap #3(2026-09-28)、12/16/24 pt と DPI 100〜200%。 |
| `font-variation` | フォント | ○ | DirectWrite のシステムフォールバックのフェイスには適用されない。 |
| `font-variation-bold` | フォント | ○ |  |
| `font-variation-italic` | フォント | ○ |  |
| `font-variation-bold-italic` | フォント | ○ |  |
| `font-codepoint-map` | フォント | ◎ | 確認記録: roadmap #3(2026-09-28)、Noto Sans JP。割り当てたフェイスにもフォールバックのサイズ調整がかかる。 |
| `clipboard-codepoint-map` | クリップボード | ○ |  |
| `font-thicken` | フォント | - | macOS(CoreText)専用。Windows で使う FreeType の描画では無視される。 |
| `font-thicken-strength` | フォント | - | macOS(CoreText)専用。Windows では無視される。 |
| `font-shaping-break` | フォント | ○ |  |
| `alpha-blending` | 描画 | ○ |  |
| `adjust-cell-width` | フォント | ○ |  |
| `adjust-cell-height` | フォント | ○ |  |
| `adjust-font-baseline` | フォント | ○ |  |
| `adjust-underline-position` | フォント | ○ |  |
| `adjust-underline-thickness` | フォント | ○ |  |
| `adjust-strikethrough-position` | フォント | ○ |  |
| `adjust-strikethrough-thickness` | フォント | ○ |  |
| `adjust-overline-position` | フォント | ○ |  |
| `adjust-overline-thickness` | フォント | ○ |  |
| `adjust-cursor-thickness` | カーソル | ○ |  |
| `adjust-cursor-height` | カーソル | ○ |  |
| `adjust-box-thickness` | フォント | ○ |  |
| `adjust-icon-height` | フォント | ○ |  |
| `grapheme-width-method` | ターミナル | ○ |  |
| `freetype-load-flags` | フォント | ○ | このビルドは FreeType でフォントを描画するため、Windows でも効く。 |
| `theme` | 色 | △ | 単一のテーマは効く。`light:`/`dark:` の組み合わせは、Windows がシステムの配色を通知しないため常にライト側になる。 |
| `background` | 色 | ◎ | 確認記録: port log 2026-10-14 の外観チェックで、設定した背景色を画素で確認。 |
| `foreground` | 色 | ○ |  |
| `background-image` | 背景 | ○ |  |
| `background-image-opacity` | 背景 | ○ |  |
| `background-image-position` | 背景 | ○ |  |
| `background-image-fit` | 背景 | ○ |  |
| `background-image-repeat` | 背景 | ○ |  |
| `selection-foreground` | 色 | ○ |  |
| `selection-background` | 色 | ○ |  |
| `selection-clear-on-typing` | 選択 | ○ |  |
| `selection-clear-on-copy` | 選択 | ○ |  |
| `selection-word-chars` | 選択 | ○ |  |
| `minimum-contrast` | 色 | ○ |  |
| `palette` | 色 | ○ |  |
| `palette-generate` | 色 | ○ |  |
| `palette-harmonious` | 色 | ○ |  |
| `cursor-color` | カーソル | ○ |  |
| `cursor-opacity` | カーソル | ○ |  |
| `cursor-style` | カーソル | ○ |  |
| `cursor-style-blink` | カーソル | ○ |  |
| `cursor-text` | カーソル | ○ |  |
| `cursor-click-to-move` | カーソル | ○ | OSC 133 のプロンプト区切りが必要。PowerShell の自動統合は出力しない。 |
| `mouse-hide-while-typing` | マウス | ○ |  |
| `scroll-to-bottom` | ターミナル | ○ |  |
| `mouse-shift-capture` | マウス | ○ |  |
| `mouse-reporting` | マウス | ○ |  |
| `mouse-scroll-multiplier` | マウス | △ | `discrete` の値だけ効く。Windows ではホイールもタッチパッドも精密スクロールとして送られないため、`precision` は無視される。 |
| `background-opacity` | 背景 | ◎ | 確認記録: port log 2026-10-14 の画素チェックと、2026-10-15 のオーナーによる手動確認。 |
| `background-opacity-cells` | 背景 | ○ |  |
| `background-blur` | 背景 | △ | `background-opacity` が 1 未満のときだけ効く。品質は環境によって異なる(#11)。`macos-glass-*` の値は `true` と同じ扱い。 |
| `unfocused-split-opacity` | タブ・分割 | ✕ | Windows ではフォーカスのないペインを暗くしない。 |
| `unfocused-split-fill` | タブ・分割 | ✕ | 無視される。Windows ではフォーカスのないペインを暗くしない。 |
| `split-divider-color` | タブ・分割 | ✕ | 無視される。仕切り線の色は背景色と前景色を混ぜて決める(ハイコントラスト時はシステム色)。 |
| `split-preserve-zoom` | タブ・分割 | ○ |  |
| `search-foreground` | 色 | ○ | ターミナル検索は 1.3.2-windows.11 で確認済み。色の指定は個別に確認していない。 |
| `search-background` | 色 | ○ | ターミナル検索は 1.3.2-windows.11 で確認済み。色の指定は個別に確認していない。 |
| `search-selected-foreground` | 色 | ○ |  |
| `search-selected-background` | 色 | ○ |  |
| `command` | シェル | ◎ | ConPTY 経由で実行する。確認記録: CLI の `--command`(port log 2026-10-17、F6)、IPC の `+new-tab -e`(port log 2026-10-15)。ネイティブの回帰スクリプトでも使用。 |
| `initial-command` | シェル | ○ | `-e` で設定される。最初のサーフェスにだけ適用される。 |
| `notify-on-command-finish` | 通知 | ◎ | OSC 133 が必要(同梱の Bash 統合、または OSC 133 を出すプロンプト)。PowerShell の自動統合は出力しない。GTK のコマンド単位のメニューはない。確認記録: port log 2026-10-18(F8)。 |
| `notify-on-command-finish-action` | 通知 | ◎ | `bell` は `bell-features` に従い、`notify` は Windows のトーストを出す。確認記録: port log 2026-10-18(F8、`bell,notify`)。 |
| `notify-on-command-finish-after` | 通知 | ◎ | 確認記録: port log 2026-10-18(F8、10 秒のしきい値。5 秒のコマンドは通知されない)。 |
| `env` | シェル | ○ | Windows の環境ブロックで ConPTY の子プロセスに渡される。 |
| `input` | シェル | ○ |  |
| `wait-after-command` | シェル | ○ | 「Process exited. Press any key」をターミナルの文字として表示する。Windows にはネイティブのダイアログはない。 |
| `abnormal-command-exit-runtime` | シェル | ○ | Linux と同じく、しきい値内に 0 以外で終了した場合だけが対象。エラーはターミナルの文字として表示される。 |
| `scrollback-limit-bytes` | スクロールバック | ○ |  |
| `scrollback-limit-lines` | スクロールバック | ◎ | 確認記録: F2 のスクロールバー履歴チェックで `scrollback-limit-lines = 64` を使用(roadmap、F2 の受け入れ)。 |
| `scrollback-compression` | スクロールバック | ○ | Windows では `DiscardVirtualMemory` を使う。 |
| `scrollbar` | スクロールバック | ◎ | `system` はスクロール中や右端へのホバー時にペインごとのオーバーレイスクロールバーを表示し、`never` は無効にする。確認記録: F2 の受け入れ。 |
| `link` | リンク | ✕ | upstream でも未実装で、どのビルドでも設定できない。組み込みの URL 判定だけがある。 |
| `link-url` | リンク | ◎ | Ctrl+クリックでテキスト中の URL を `ShellExecuteW` で開く。確認記録: roadmap #47(2026-10-12)。 |
| `link-osc8` | リンク | ◎ | http/https/mailto は開き、それ以外のスキームは確認を求め、`file:` リンクはブロックする。確認記録: roadmap #36(2026-10-12)。 |
| `link-previews` | リンク | ✕ | Win32 はホバー中のリンクの URL を表示しないため、この設定は見た目に影響しない。 |
| `maximize` | ウィンドウ | ◎ | Quick terminal には適用されない。確認記録: port log 2026-10-15(#12 の最終確認)。 |
| `fullscreen` | ウィンドウ | ◎ | macOS の非ネイティブモードの値は `true` と同じ扱い。Quick terminal には適用されない。確認記録: port log 2026-10-15(#12)。 |
| `title` | ウィンドウ | ◎ | IPC の `+new-tab --title`(新しいタブにこの設定を与える)で確認(port log 2026-10-15)。 |
| `class` | GTK | - | GTK 専用(WM_CLASS、Wayland のアプリ ID、DBus)。Windows では `+new-tab --class` を受け付けない。 |
| `x11-instance-name` | GTK | - | X11 専用。 |
| `working-directory` | シェル | ◎ | 値を明示するとセッションの復元を行わない。確認記録: port log 2026-10-17(F6)と IPC の `--working-directory`(2026-10-15)。 |
| `keybind` | キーバインド | ◎ | `global:` は `RegisterHotKey` を使う。シーケンス、複数アクション、Shift/AltGr が必要な文字、使用済みの組み合わせは診断を出して拒否する。確認記録: port log 2026-10-17(F7)。 |
| `key-remap` | キーバインド | ○ | キーバインドの照合とエンコードに適用される。Windows のキーボード配列が生成する文字は変わらない。 |
| `window-padding-x` | ウィンドウ | ○ | 共通コアのサーフェスのサイズ計算で適用される。Win32 は IME の位置と分割の最小サイズにコアのパディングを使う。 |
| `window-padding-y` | ウィンドウ | ○ | 共通コアのサーフェスのサイズ計算で適用される。 |
| `window-padding-balance` | ウィンドウ | ○ |  |
| `window-padding-color` | ウィンドウ | ○ |  |
| `window-vsync` | 描画 | ○ | upstream の説明は macOS のみだが、D3D11 の描画は `true` で同期間隔 1、`false` で 0 で表示する。 |
| `window-inherit-working-directory` | 作業ディレクトリ | ◎ | シェルからの OSC 7 が必要(PowerShell 統合は自動)。確認記録: roadmap の検証一覧、1.3.2-windows.11。 |
| `tab-inherit-working-directory` | 作業ディレクトリ | ◎ | シェルからの OSC 7 が必要。確認記録: roadmap の検証一覧、1.3.2-windows.11。 |
| `split-inherit-working-directory` | 作業ディレクトリ | ◎ | シェルからの OSC 7 が必要。確認記録: roadmap の検証一覧、1.3.2-windows.11。 |
| `window-inherit-font-size` | ウィンドウ | ✕ | 新しいウィンドウ、タブ、分割は常に設定した `font-size` で始まる。 |
| `window-decoration` | ウィンドウ | ○ | `none` はネイティブの枠を外す。`auto`、`client`、`server` はどれも Windows のネイティブの枠を使う。 |
| `window-title-font-family` | タイトルバー | ✕ | ネイティブのタイトルバーはシステムフォント、タブバーは Segoe UI を使う。 |
| `window-subtitle` | GTK | - | GTK 専用のサブタイトル。Windows のタイトルバーにはサブタイトルがない。 |
| `window-theme` | タイトルバー | ◎ | ネイティブのタイトルバーに適用される。確認記録: port log 2026-10-15 のまとめての手動確認(`ghostty`、`dark`、`light`)。`system` は未確認。 |
| `window-colorspace` | 描画 | ✕ | Windows では `display-p3` は無視され、色は常に sRGB として扱われる。 |
| `window-height` | ウィンドウ | ◎ | 確認記録: ウィンドウ状態の回帰テストで、起動時の ConPTY の行数を確認(2026-09-15 の修正)。 |
| `window-width` | ウィンドウ | ◎ | 確認記録: ウィンドウ状態の回帰テストで、起動時のサイズを確認(2026-09-15 の修正)。 |
| `window-position-x` | ウィンドウ | ✕ | 初期位置は Windows が決める(`CW_USEDEFAULT`)。セッションの復元ではウィンドウを配置できる。 |
| `window-position-y` | ウィンドウ | ✕ | 初期位置は Windows が決める(`CW_USEDEFAULT`)。 |
| `window-save-state` | セッション | ◎ | 保存と復元を有効にするのは `always` だけで、`default` と `never` は保存しない。確認記録: port log 2026-10-17(F6)。 |
| `window-step-resize` | ウィンドウ | ✕ | Windows ではピクセル単位でサイズが変わる。 |
| `window-new-tab-position` | タブ・分割 | ○ |  |
| `window-show-tab-bar` | タブ・分割 | ◎ | `auto` では分割をズームしている間もタブバーを表示する。確認記録: 再読み込みの自動回帰テスト(roadmap の検証一覧)。 |
| `window-titlebar-background` | タイトルバー | ○ | `window-theme = ghostty` のときだけ、Windows 11 で効く。ハイコントラスト時は解除される。 |
| `window-titlebar-foreground` | タイトルバー | ○ | `window-theme = ghostty` のときだけ、Windows 11 で効く。タブバーの文字と仕切り線の色にも使われる。 |
| `drag-handle` | タブ・分割 | ✕ | Windows には分割のドラッグハンドルがなく、マウスで分割を並べ替えられない(仕切り線でのサイズ変更はできる)。 |
| `resize-overlay` | ウィンドウ | ✕ | Windows にはサイズ変更時のサイズ表示がない。 |
| `resize-overlay-position` | ウィンドウ | ✕ | Windows にはサイズ変更時のサイズ表示がない。 |
| `resize-overlay-duration` | ウィンドウ | ✕ | Windows にはサイズ変更時のサイズ表示がない。 |
| `focus-follows-mouse` | マウス | ✕ | ペインのフォーカスはクリックでだけ変わる。 |
| `clipboard-read` | クリップボード | ○ | `ask` は Windows の確認ダイアログを表示する。 |
| `clipboard-write` | クリップボード | ◎ | `ask` は Windows の確認ダイアログを表示する。確認記録: 既定値での OSC 52 の書き込み(port log 2026-10-17、F5)。`ask`/`deny` は記録なし。 |
| `clipboard-write-limit-bytes` | クリップボード | ○ | Kitty クリップボードプロトコル(OSC 5522)の書き込みに適用される。 |
| `clipboard-trim-trailing-spaces` | クリップボード | ○ |  |
| `clipboard-paste-protection` | クリップボード | ○ | 危険な貼り付けでは Windows の確認ダイアログを表示する。ファイルのドロップにも同じ保護がかかる。 |
| `clipboard-paste-bracketed-safe` | クリップボード | ○ |  |
| `title-report` | ターミナル | ○ |  |
| `image-storage-limit` | ターミナル | ○ | Kitty graphics には同梱の OpenConsole(ConPTY ホスト)が必要。 |
| `copy-on-select` | 選択 | △ | `primary` は何もコピーしない(Windows には選択範囲用のクリップボードがない)。`both` はシステムのクリップボードにだけコピーする。既定値は `none`。 |
| `right-click-action` | マウス | ◎ | 確認記録: 既定の `context-menu` を 1.3.2-windows.11 と 2026-10-15 のまとめての手動確認で確認。ほかの値は記録なし。 |
| `middle-click-action` | マウス | △ | 既定の `primary-paste` は Windows では何もしない(選択範囲用のクリップボードがない)。`clipboard-paste` を使う。 |
| `click-repeat-interval` | マウス | ○ | `0` のときは 500 ms を使い、Windows のダブルクリック時間の設定は使わない。 |
| `config-file` | 設定 | ○ |  |
| `config-default-files` | 設定 | ◎ | 確認記録: 回帰スクリプトとシェルの受け入れスクリプトが `--config-default-files=false` で隔離したプロセスを起動している。 |
| `confirm-close-surface` | 起動・終了 | ◎ | Windows のネイティブの確認ダイアログを表示する。確認記録: モーダル操作とネイティブの終了確認のチェック(port log 2026-10-14)。 |
| `quit-after-last-window-closed` | 起動・終了 | ◎ | `false` で動作し続けるのは、global キーバインドが登録されている間だけ。それ以外は終了する。確認記録: port log 2026-10-17(F7)。 |
| `quit-after-last-window-closed-delay` | 起動・終了 | ✕ | 最後のウィンドウを閉じるとすぐに終了する。 |
| `initial-window` | 起動・終了 | ✕ | 起動時は常にウィンドウを開く(またはセッションを復元する)。 |
| `undo-timeout` | 起動・終了 | ✕ | 閉じたペイン、タブ、ウィンドウの取り消し/やり直しは Windows では使えない。 |
| `quick-terminal-position` | Quick terminal | ◎ | モニターの作業領域の端または中央。確認記録: port log 2026-10-17(F7)。 |
| `quick-terminal-size` | Quick terminal | ◎ | px の値はデバイスピクセル。確認記録: port log 2026-10-17(F7)。 |
| `gtk-quick-terminal-layer` | GTK | - | Wayland の layer-shell 専用。Windows では無視される。 |
| `gtk-quick-terminal-namespace` | GTK | - | Wayland の layer-shell 専用。Windows では無視される。 |
| `quick-terminal-screen` | Quick terminal | ◎ | `main` はプライマリモニター。`macos-menu-bar` は `main` と同じ扱い。確認記録: port log 2026-10-17(F7、`mouse`)。 |
| `quick-terminal-animation-duration` | Quick terminal | ✕ | Quick terminal はアニメーションなしで表示・非表示になる。 |
| `quick-terminal-autohide` | Quick terminal | ◎ | Windows での既定値は `false`。確認記録: port log 2026-10-17(F7)。 |
| `quick-terminal-space-behavior` | macOS | - | macOS の Spaces 専用。仮想デスクトップを切り替えても、Quick terminal は表示したデスクトップに残る。 |
| `quick-terminal-keyboard-interactivity` | Quick terminal | ◎ | `exclusive` は `on-demand` と同じ扱い。確認記録: port log 2026-10-17(F7、`none` と `on-demand`)。 |
| `shell-integration` | シェル統合 | △ | PowerShell の自動統合は作業ディレクトリ(OSC 7)だけを通知し、プロンプトの区切りや OSC 133 は出さない。Bash 統合は同梱。PowerShell の作業ディレクトリの確認記録: port log 2026-10-17(F6)。 |
| `shell-integration-features` | シェル統合 | △ | `GHOSTTY_SHELL_FEATURES` として渡され、同梱の Bash 統合が従う(`ssh-terminfo`、`ssh-env` など)。PowerShell 統合はこれらを無視する。 |
| `command-palette-entry` | コマンドパレット | ◎ | 確認記録: roadmap F1(#17)、オーナーによる実機での受け入れ。 |
| `osc-color-report-format` | ターミナル | ○ | 共通コアで処理される。関係するシーケンスを ConPTY が通すかは未確認。 |
| `vt-kam-allowed` | ターミナル | ○ | 共通コアで処理される。関係するシーケンスを ConPTY が通すかは未確認。 |
| `vt-window-resize-allowed` | ターミナル | ◎ | 確認記録: port log の resize_window(#45)、Debug ビルドでの CSI 8 t のチェック。作業領域と最大化状態を考慮してサイズを変える。 |
| `vt-xt-checksum-report` | ターミナル | ○ | 共通コアで処理される。関係するシーケンスを ConPTY が通すかは未確認。 |
| `vt-xt-checksum-extension` | ターミナル | ○ | 共通コアで処理される。関係するシーケンスを ConPTY が通すかは未確認。 |
| `custom-shader` | 描画 | ✕ | D3D11 の描画はカスタムシェーダーに対応しておらず、ログに警告を出して無視する(#14)。 |
| `custom-shader-animation` | 描画 | ✕ | D3D11 の描画がカスタムシェーダーに対応していないため効果がない(#14)。 |
| `bell-features` | ベル | △ | `system`、`attention`、`title` は効く(確認記録: port log 2026-10-18、F8)。`audio` と `border` は非対応。 |
| `bell-audio-path` | ベル | ✕ | 音声のベルは Windows では非対応。 |
| `bell-audio-volume` | ベル | ✕ | 音声のベルは Windows では非対応。 |
| `app-notifications` | GTK | - | GTK 専用のアプリ内トースト(`clipboard-copy`、`config-reload`)。 |
| `macos-non-native-fullscreen` | macOS | - |  |
| `macos-window-buttons` | macOS | - |  |
| `macos-titlebar-style` | macOS | - |  |
| `macos-titlebar-proxy-icon` | macOS | - |  |
| `macos-dock-drop-behavior` | macOS | - |  |
| `macos-option-as-alt` | macOS | - |  |
| `macos-window-shadow` | macOS | - |  |
| `macos-hidden` | macOS | - |  |
| `macos-auto-secure-input` | macOS | - |  |
| `macos-secure-input-indication` | macOS | - |  |
| `macos-applescript` | macOS | - |  |
| `macos-icon` | macOS | - |  |
| `macos-custom-icon` | macOS | - |  |
| `macos-icon-frame` | macOS | - |  |
| `macos-icon-ghost-color` | macOS | - |  |
| `macos-icon-screen-color` | macOS | - |  |
| `macos-shortcuts` | macOS | - |  |
| `linux-cgroup` | Linux | - |  |
| `linux-cgroup-memory-limit` | Linux | - |  |
| `linux-cgroup-processes-limit` | Linux | - |  |
| `linux-cgroup-hard-fail` | Linux | - |  |
| `gtk-opengl-debug` | GTK | - |  |
| `gtk-single-instance` | GTK | - |  |
| `gtk-titlebar` | GTK | - |  |
| `gtk-tabs-location` | GTK | - |  |
| `gtk-titlebar-hide-when-maximized` | GTK | - |  |
| `gtk-toolbar-style` | GTK | - |  |
| `gtk-titlebar-style` | GTK | - |  |
| `gtk-wide-tabs` | GTK | - |  |
| `gtk-horizontal-tab-scroll` | GTK | - |  |
| `gtk-custom-css` | GTK | - |  |
| `desktop-notifications` | 通知 | ◎ | OSC 9/777 を Windows のトーストで通知する。同梱の ConPTY が必要。確認記録: port log 2026-10-18(F8)。 |
| `progress-style` | タスクバー | ◎ | OSC 9;4 の進捗をタスクバーに表示する。確認記録: roadmap F4(#33)、オーナーによる実機のタスクバーでの受け入れ(port log 2026-10-17)。 |
| `bold-color` | 色 | ○ |  |
| `faint-opacity` | 色 | ○ |  |
| `term` | ターミナル | ◎ | 既定は `TERM=xterm-ghostty` で、`TERMINFO` はインストール先を指す。確認記録: roadmap 2026-09-15 の terminfo の修正(`tput` によるチェック)。 |
| `enquiry-response` | ターミナル | ○ | 共通コアで処理される。関係するシーケンスを ConPTY が通すかは未確認。 |
| `async-backend` | Linux | - | Linux 専用(epoll/io_uring)。 |
| `auto-update` | 更新 | - | macOS(Sparkle)専用。 |
| `auto-update-channel` | 更新 | - | macOS(Sparkle)専用。 |

凡例:

- ◎ Windows で使える。動作確認の記録がある。
- ○ Windows で使える(コードから判断)。動作確認の記録はない。
- △ 一部だけ使える。使えない部分は備考に書いている。
- ✕ Windows では未実装。設定しても効果がない。
- \- 対象外。macOS、GTK、Linux、X11、Wayland だけに関係する設定。
