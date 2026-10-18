# Windows での設定の対応状況

この文書は [Configuration Support on Windows](windows-config-support.md) の
日本語版です。内容が異なる場合は英語版が正です。

upstream の Ghostty の全設定項目(`src/config/Config.zig`)について、
`1.3.2-windows.16` 時点のネイティブ Windows ビルドでの対応状況をまとめています。
項目は upstream のリファレンスと同じ順に並べ、内容は upstream の説明を要約した
ものです。設定ファイルの場所と Windows 固有の動作は[ユーザーガイド](windows.md)
(英語)を参照してください。

◎ は、その設定またはそれが制御する機能を実際に動かして確認した記録が
[port log](windows-port-log.md) か [roadmap](windows-roadmap.md) にあるものです。
○ はコードを読んで判断したもので、その設定を処理するコードは Windows で動きますが、
動作確認の記録はありません。△ と ✕ もコードからの判断です。

| 設定項目 | 分類 | 状態 | 内容 |
|---|---|---|---|
| `language` | GTK | - | システム既定に代わって使う、Ghostty の GUI の表示言語。 |
| `font-family` | フォント | ◎ | 通常テキストに使うフォントファミリーで、繰り返し指定すると文字がない場合のフォールバックフォントも列挙できる。 |
| `font-family-bold` | フォント | ○ | 太字に使うフォントファミリーで、未設定または見つからない場合は `font-family` を使う。 |
| `font-family-italic` | フォント | ○ | 斜体に使うフォントファミリーで、未設定または見つからない場合は `font-family` を使う。 |
| `font-family-bold-italic` | フォント | ○ | 太字斜体に使うフォントファミリーで、未設定または見つからない場合は `font-family` を使う。 |
| `font-style` | フォント | ○ | 指定フォントファミリーのうち、通常テキストに使う名前付きスタイル（`Heavy` など）。 |
| `font-style-bold` | フォント | ○ | 太字に使う名前付きフォントスタイルで、`false` にすると太字を無効化できる。 |
| `font-style-italic` | フォント | ○ | 斜体に使う名前付きフォントスタイルで、`false` にすると斜体を無効化できる。 |
| `font-style-bold-italic` | フォント | ○ | 太字斜体に使う名前付きフォントスタイルで、`false` にすると太字斜体を無効化できる。 |
| `font-synthetic-style` | フォント | ○ | フォントに太字・斜体・太字斜体がない場合に、それらを合成するかどうか。 |
| `font-feature` | フォント | ○ | 有効化・無効化する OpenType フォント機能（合字を止める `-calt` など）。 |
| `font-size` | フォント | ◎ | 小数も指定できる、ポイント単位のフォントサイズ。 |
| `font-variation` | フォント | ○ | 通常テキストに適用する可変フォントの軸の値（`wght=500` など）。 |
| `font-variation-bold` | フォント | ○ | 太字に適用する可変フォントの軸の値。 |
| `font-variation-italic` | フォント | ○ | 斜体に適用する可変フォントの軸の値。 |
| `font-variation-bold-italic` | フォント | ○ | 太字斜体に適用する可変フォントの軸の値。 |
| `font-codepoint-map` | フォント | ◎ | 特定の Unicode コードポイントまたは範囲を、指定したフォントで描画させる設定。 |
| `clipboard-codepoint-map` | クリップボード | ○ | クリップボードへのコピー時に、特定の Unicode コードポイントを別の文字や文字列に置き換える設定。 |
| `font-thicken` | フォント | - | 対応環境でフォントを太い線で描画するかどうか。 |
| `font-thicken-strength` | フォント | - | `font-thicken` 有効時の太らせる強さ（`0`〜`255`）。 |
| `font-shaping-break` | フォント | ○ | テキストのシェーピングを分割する位置（合字を崩す `cursor` 位置など）。 |
| `alpha-blending` | 描画 | ○ | テキストや透過画像のアルファブレンディングに使う色空間。 |
| `adjust-cell-width` | フォント | ○ | セル幅をピクセルまたはパーセントで調整する値。 |
| `adjust-cell-height` | フォント | ○ | セルの高さをピクセルまたはパーセントで調整する値で、テキストは縦中央に配置される。 |
| `adjust-font-baseline` | フォント | ○ | セル下端からテキストのベースラインまでの距離の調整値。 |
| `adjust-underline-position` | フォント | ○ | セル上端から下線までの距離の調整値。 |
| `adjust-underline-thickness` | フォント | ○ | 下線の太さの調整値。 |
| `adjust-strikethrough-position` | フォント | ○ | セル上端から取り消し線までの距離の調整値。 |
| `adjust-strikethrough-thickness` | フォント | ○ | 取り消し線の太さの調整値。 |
| `adjust-overline-position` | フォント | ○ | セル上端から上線までの距離の調整値。 |
| `adjust-overline-thickness` | フォント | ○ | 上線の太さの調整値。 |
| `adjust-cursor-thickness` | カーソル | ○ | バーカーソルと枠線ブロックカーソルの太さの調整値。 |
| `adjust-cursor-height` | カーソル | ○ | すべてのカーソル形状に適用されるカーソルの高さの調整値。 |
| `adjust-box-thickness` | フォント | ○ | 罫線文字の線の太さの調整値。 |
| `adjust-icon-height` | フォント | ○ | Nerd Font アイコンの最大の高さの調整値。 |
| `grapheme-width-method` | ターミナル | ○ | 書記素クラスタのセル幅の算出方法（`unicode` または `legacy`）。 |
| `freetype-load-flags` | フォント | ○ | ヒンティング、オートヒント、モノクロ描画など、FreeType のグリフ読み込みフラグ。 |
| `theme` | 色 | △ | 名前またはパスで読み込むカラーテーマ（ライト／ダークモード別の指定も可）。 |
| `background` | 色 | ◎ | ウィンドウの背景色。 |
| `foreground` | 色 | ○ | ウィンドウの前景色（文字色）。 |
| `background-image` | 背景 | ○ | ターミナルの背景に表示する PNG または JPEG 画像のパス。 |
| `background-image-opacity` | 背景 | ○ | `background-opacity` を基準とした背景画像の不透明度。 |
| `background-image-position` | 背景 | ○ | ターミナル内での背景画像の配置位置（`center`、`top-left` など）。 |
| `background-image-fit` | 背景 | ○ | 背景画像の拡大縮小方法（`contain`、`cover`、`stretch`、`none`）。 |
| `background-image-repeat` | 背景 | ○ | 周囲の空白を埋めるように背景画像を繰り返し並べるかどうか。 |
| `selection-foreground` | 色 | ○ | 選択範囲の文字色。 |
| `selection-background` | 色 | ○ | 選択範囲の背景色。 |
| `selection-clear-on-typing` | 選択 | ○ | 文字入力や IME の変換開始時に現在の選択を解除するかどうか。 |
| `selection-clear-on-copy` | 選択 | ○ | `copy_to_clipboard` バインドでコピーした後に選択を解除するかどうか。 |
| `selection-word-chars` | 選択 | ○ | ダブルクリックなどで単語を選択する際に単語の区切りとみなす文字。 |
| `minimum-contrast` | 色 | ○ | 文字色と背景色の間の最小コントラスト比（WCAG 基準、1〜21）。 |
| `palette` | 色 | ○ | ターミナルの 256 色パレットの各色（`N=COLOR` 形式で指定）。 |
| `palette-generate` | 色 | ○ | 基本 16 色の ANSI カラーからパレットの 16〜255 番を自動生成するかどうか。 |
| `palette-harmonious` | 色 | ○ | ライト／ダーク両対応のため `palette-generate` で生成した色の並びを反転するかどうか。 |
| `cursor-color` | カーソル | ○ | カーソルの色（セルに合わせる `cell-foreground`／`cell-background` も指定可）。 |
| `cursor-opacity` | カーソル | ○ | カーソルの不透明度（0 で透明、1 で不透明）。 |
| `cursor-style` | カーソル | ○ | カーソルの既定の形状（`block`、`bar`、`underline`、`block_hollow`）。 |
| `cursor-style-blink` | カーソル | ○ | カーソルの既定の点滅状態（未設定時は DEC モード 12 にも従う）。 |
| `cursor-text` | カーソル | ○ | カーソル下の文字の色。 |
| `cursor-click-to-move` | カーソル | ○ | `OSC 133` のプロンプトマークを使い、プロンプト内のクリック位置へカーソルを移動するかどうか。 |
| `mouse-hide-while-typing` | マウス | ○ | 入力中はマウスを再び操作するまでマウスポインターを隠すかどうか。 |
| `scroll-to-bottom` | ターミナル | ○ | 最下部へスクロールする契機（`keystroke`、新しい `output`、またはその両方）。 |
| `mouse-shift-capture` | マウス | ○ | マウスクリック時の Shift をプログラムへ送るか、選択範囲の拡張に使うか。 |
| `mouse-reporting` | マウス | ○ | 要求したターミナルアプリケーションにマウスイベントを報告するかどうか。 |
| `mouse-scroll-multiplier` | マウス | △ | マウスホイールのスクロール量の倍率（`precision:`／`discrete:` のデバイス別指定も可）。 |
| `background-opacity` | 背景 | ◎ | ウィンドウ背景の不透明度（0 で透明、1 で不透明）。 |
| `background-opacity-cells` | 背景 | ○ | 明示的な背景色を持つセルにも `background-opacity` を適用するかどうか。 |
| `background-blur` | 背景 | △ | 半透明ウィンドウの背後をぼかすかどうかと、その強さ。 |
| `unfocused-split-opacity` | タブ・分割 | ✕ | フォーカスのない分割ペインの不透明度（フォーカス中のペインを目立たせるための減光）。 |
| `unfocused-split-fill` | タブ・分割 | ✕ | フォーカスのない分割ペインを減光する重ね塗りの色。 |
| `split-divider-color` | タブ・分割 | ✕ | 分割ペイン間の区切り線の色。 |
| `split-preserve-zoom` | タブ・分割 | ○ | ズーム中の分割ペインのズームを維持する操作（分割間の `navigation` など）。 |
| `search-foreground` | 色 | ○ | フォーカスされていない検索一致箇所の文字色。 |
| `search-background` | 色 | ○ | フォーカスされていない検索一致箇所の背景色。 |
| `search-selected-foreground` | 色 | ○ | 現在選択中の検索一致箇所の文字色。 |
| `search-selected-background` | 色 | ○ | 現在選択中の検索一致箇所の背景色。 |
| `command` | シェル | ◎ | 新しいターミナルサーフェスごとに実行するコマンド（通常はシェル）。 |
| `initial-command` | シェル | ○ | `command` と同様だが、Ghostty 起動時に最初に作成されるターミナルサーフェスにのみ適用されるコマンド。 |
| `notify-on-command-finish` | 通知 | ◎ | コマンド終了時に通知を送る条件（`never`、`unfocused`、`always`）。 |
| `notify-on-command-finish-action` | 通知 | ◎ | コマンド終了通知の方法（`bell`、`notify` など）。 |
| `notify-on-command-finish-after` | 通知 | ◎ | コマンド終了通知を送る対象となる、コマンドの最低実行時間。 |
| `env` | シェル | ○ | ターミナルサーフェスで起動するコマンドに渡す追加の環境変数（`KEY=VALUE` 形式）。 |
| `input` | シェル | ○ | 起動時にコマンドへ入力として送るデータ（`raw:` の文字列または `path:` のファイル）。 |
| `wait-after-command` | シェル | ○ | コマンド終了後、キーが押されるまでターミナルを開いたままにするかどうか。 |
| `abnormal-command-exit-runtime` | シェル | ○ | この時間（ミリ秒）未満でプロセスが終了した場合に異常終了とみなしてエラーを表示する閾値。 |
| `scrollback-limit-bytes` | スクロールバック | ○ | ターミナルサーフェスごとのスクロールバックバッファの最大サイズ（バイト）。 |
| `scrollback-limit-lines` | スクロールバック | ◎ | 保持するスクロールバックの最大行数（アクティブな画面を除く）。 |
| `scrollback-compression` | スクロールバック | ○ | ターミナルのアイドル時にスクロールバックのページをメモリ上で圧縮するかどうか。 |
| `scrollbar` | スクロールバック | ◎ | スクロールバックバッファのスクロールバーを表示する条件（`system` または `never`）。 |
| `link` | リンク | ✕ | ターミナルのテキストに正規表現でマッチさせ、クリック時の動作を割り当てる設定（現時点では設定不可）。 |
| `link-url` | リンク | ◎ | URL を検出し、修飾キー付きクリックで既定のアプリケーションで開くかどうか。 |
| `link-osc8` | リンク | ◎ | OSC 8 エスケープシーケンスで作成されたハイパーリンクを有効にするかどうか。 |
| `link-previews` | リンク | ✕ | マッチした URL のリンクプレビューを表示するかどうか（`true`、`false`、`osc8` のみ）。 |
| `maximize` | ウィンドウ | ◎ | 新しいウィンドウを最大化した状態で開始するかどうか。 |
| `fullscreen` | ウィンドウ | ◎ | 新しいウィンドウをフルスクリーンで開始するかどうか（macOS の非ネイティブフルスクリーンを含む）。 |
| `title` | ウィンドウ | ◎ | プログラムがエスケープシーケンスで設定するタイトルを無視して固定するウィンドウタイトル。 |
| `class` | GTK | - | GTK でのアプリケーションクラス（X11 の `WM_CLASS` のクラス、Wayland のアプリケーション ID、DBus 名）。 |
| `x11-instance-name` | GTK | - | GTK ビルドにおける X11 の `WM_CLASS` プロパティのインスタンス名。 |
| `working-directory` | シェル | ◎ | コマンド起動後に移動する作業ディレクトリ（パス、`home`、`inherit`）。 |
| `keybind` | キーバインド | ◎ | キーと修飾キーの組み合わせ（`trigger`）を `action` に割り当てるキーバインド。 |
| `key-remap` | キーバインド | ○ | Ghostty 内でのみ修飾キーを割り当て直す設定（`from=to` 形式）。 |
| `window-padding-x` | ウィンドウ | ○ | 端末セルとウィンドウの左右の境界との間の余白。 |
| `window-padding-y` | ウィンドウ | ○ | 端末セルとウィンドウの上下の境界との間の余白。 |
| `window-padding-balance` | ウィンドウ | ○ | セルサイズで割り切れずに余る領域を四辺に均等に振り分けるかどうか。 |
| `window-padding-color` | ウィンドウ | ○ | 余白領域の色。`background` の色か、最も近いセルの背景色の延長かを選ぶ。 |
| `window-vsync` | 描画 | ○ | 描画を画面のリフレッシュレートに同期させるかどうか(ティアリングと入力遅延のトレードオフ)。 |
| `window-inherit-working-directory` | 作業ディレクトリ | ◎ | 新しいウィンドウが直前にフォーカスされていたウィンドウの作業ディレクトリを引き継ぐかどうか。 |
| `tab-inherit-working-directory` | 作業ディレクトリ | ◎ | 新しいタブが直前にフォーカスされていたタブの作業ディレクトリを引き継ぐかどうか。 |
| `split-inherit-working-directory` | 作業ディレクトリ | ◎ | 新しい分割ペインが直前にフォーカスされていた分割の作業ディレクトリを引き継ぐかどうか。 |
| `window-inherit-font-size` | ウィンドウ | ✕ | 新しいウィンドウやタブが直前にフォーカスされていたウィンドウのフォントサイズを引き継ぐかどうか。 |
| `window-decoration` | ウィンドウ | ○ | タイトルバーや枠などのウィンドウ装飾の希望設定(OS 側で上書きされる場合がある)。 |
| `window-title-font-family` | タイトルバー | ✕ | アプリケーションのウィンドウタイトルとタブタイトルに使うフォント。 |
| `window-subtitle` | GTK | - | ウィンドウのサブタイトルに表示するテキスト(サーフェスの `working-directory` など)。 |
| `window-theme` | タイトルバー | ◎ | ウィンドウに使うテーマ(`auto`、`system`、`light`、`dark`、`ghostty`)。 |
| `window-colorspace` | 描画 | ✕ | 端末の色を解釈する色空間(`srgb` または `display-p3`)。 |
| `window-height` | ウィンドウ | ◎ | ウィンドウの初期の高さ(端末グリッドのセル数)。`window-width` も設定する必要がある。 |
| `window-width` | ウィンドウ | ◎ | ウィンドウの初期の幅(端末グリッドのセル数)。`window-height` も設定する必要がある。 |
| `window-position-x` | ウィンドウ | ✕ | プライマリモニターの左上を基準とした、ウィンドウの初期の横位置(ピクセル)。`window-position-y` も必要。 |
| `window-position-y` | ウィンドウ | ✕ | プライマリモニターの左上を基準とした、ウィンドウの初期の縦位置(ピクセル)。`window-position-x` も必要。 |
| `window-save-state` | セッション | ◎ | 位置、サイズ、タブ、分割などのウィンドウ状態を保存・復元するかどうか。 |
| `window-step-resize` | ウィンドウ | ✕ | ウィンドウをピクセル単位ではなくフォーカス中のサーフェスのセルサイズ単位でリサイズするかどうか。 |
| `window-new-tab-position` | タブ・分割 | ○ | 新しいタブを挿入する位置(`current` のタブの後ろ、または `end`)。 |
| `window-show-tab-bar` | タブ・分割 | ◎ | タブバーを表示する条件(`always`、またはタブが2つ以上あるときのみなど)。 |
| `window-titlebar-background` | タイトルバー | ○ | `window-theme` が `ghostty` のときのウィンドウタイトルバーの背景色。 |
| `window-titlebar-foreground` | タイトルバー | ○ | `window-theme` が `ghostty` のときのウィンドウタイトルバーの前景色。 |
| `drag-handle` | タブ・分割 | ✕ | マウスで分割を並べ替えるためのドラッグハンドルを分割上に表示する条件。 |
| `resize-overlay` | ウィンドウ | ✕ | リサイズ中に端末サイズを示す一時的なオーバーレイを表示する条件。 |
| `resize-overlay-position` | ウィンドウ | ✕ | リサイズオーバーレイの表示位置(`center`、`top-left` など)。 |
| `resize-overlay-duration` | ウィンドウ | ✕ | リサイズオーバーレイが非表示になるまでの表示時間。 |
| `focus-follows-mouse` | マウス | ✕ | フォーカス中のウィンドウで、マウスを重ねた分割ペインにフォーカスを移すかどうか。 |
| `clipboard-read` | クリップボード | ○ | 端末内のプログラムが OSC 52 でシステムクリップボードを読み取れるかどうか(`ask`、`allow`、`deny`)。 |
| `clipboard-write` | クリップボード | ◎ | 端末内のプログラムが OSC 52 でシステムクリップボードに書き込めるかどうか(`ask`、`allow`、`deny`)。 |
| `clipboard-write-limit-bytes` | クリップボード | ○ | Kitty クリップボードプロトコル(OSC 5522)による1回のクリップボード書き込みの最大バイト数。 |
| `clipboard-trim-trailing-spaces` | クリップボード | ○ | クリップボードにコピーするテキストから行末の空白を取り除くかどうか。 |
| `clipboard-paste-protection` | クリップボード | ○ | 改行を含むテキストなど、安全でなさそうなテキストを貼り付ける前に確認を求めるかどうか。 |
| `clipboard-paste-bracketed-safe` | クリップボード | ○ | プログラムがブラケットペーストモードを有効にしているときの貼り付けを安全とみなすかどうか。 |
| `title-report` | ターミナル | ○ | プログラムがタイトル報告(CSI 21 t)で端末タイトルを問い合わせられるかどうか。 |
| `image-storage-limit` | ターミナル | ○ | 端末画面ごとの画像データ(Kitty 画像プロトコルなど)の最大バイト数。 |
| `copy-on-select` | 選択 | △ | 選択したテキストを自動でコピーするかどうかとコピー先(`none`、`primary`、`clipboard`、`both`)。 |
| `right-click-action` | マウス | ◎ | 右クリック時の動作(`context-menu`、`paste`、`copy`、`copy-or-paste`、`ignore`)。 |
| `middle-click-action` | マウス | △ | 中クリック時の動作(`primary-paste`、`clipboard-paste`、`ignore`)。 |
| `click-repeat-interval` | マウス | ○ | ダブルクリックやトリプルクリックとみなすクリック間隔の上限(ミリ秒)。 |
| `config-file` | 設定 | ○ | 追加で読み込む設定ファイル。繰り返し指定でき、先頭の `?` で存在しないファイルを無視する。 |
| `config-default-files` | 設定 | ◎ | 既定の設定ファイルパスを読み込むかどうか(コマンドラインでのみ指定可能)。 |
| `confirm-close-surface` | 起動・終了 | ◎ | サーフェスを閉じる前に確認するかどうか(`true`、`false`、`always`)。 |
| `quit-after-last-window-closed` | 起動・終了 | ◎ | 最後のサーフェスを閉じた後にアプリケーションを終了するかどうか。 |
| `quit-after-last-window-closed-delay` | 起動・終了 | ✕ | `quit-after-last-window-closed` が `true` のとき、最後のサーフェスを閉じてから Ghostty が終了するまでの時間。 |
| `initial-window` | 起動・終了 | ✕ | Ghostty の起動時に最初のウィンドウを作成するかどうか。 |
| `undo-timeout` | 起動・終了 | ✕ | 各操作を取り消し可能なまま取り消し履歴に保持する時間。 |
| `quick-terminal-position` | Quick terminal | ◎ | クイックターミナルの画面上の位置(`top`、`bottom`、`left`、`right`、`center`)。 |
| `quick-terminal-size` | Quick terminal | ◎ | クイックターミナルのサイズ(画面に対する割合またはピクセル数)。 |
| `gtk-quick-terminal-layer` | GTK | - | クイックターミナルウィンドウのレイヤー(どのウィンドウより前面に表示されるかを決める)。 |
| `gtk-quick-terminal-namespace` | GTK | - | Wayland コンポジターやスクリプトが参照する、クイックターミナルウィンドウの名前空間識別子。 |
| `quick-terminal-screen` | Quick terminal | ◎ | クイックターミナルを表示する画面(`main`、`mouse`、`macos-menu-bar` など)。 |
| `quick-terminal-animation-duration` | Quick terminal | ✕ | クイックターミナルの表示・非表示アニメーションの秒数(`0` で無効)。 |
| `quick-terminal-autohide` | Quick terminal | ◎ | フォーカスが別のウィンドウに移ったときにクイックターミナルを自動で隠すかどうか。 |
| `quick-terminal-space-behavior` | macOS | - | macOS のスペース切り替え時にクイックターミナルが追従するかどうか(`move` または `remain`)。 |
| `quick-terminal-keyboard-interactivity` | Quick terminal | ◎ | クイックターミナルがキーボード入力を受け取る条件(Wayland layer-shell のキーボード操作モードに準拠)。 |
| `shell-integration` | シェル統合 | △ | シェル統合を自動注入するかどうかと、使用するシェルの方式。 |
| `shell-integration-features` | シェル統合 | △ | 有効にするシェル統合機能(`cursor`、`sudo`、`title`、SSH 関連など)。 |
| `command-palette-entry` | コマンドパレット | ◎ | コマンドパレットに追加する独自項目(タイトル、アクション、任意の説明)。 |
| `osc-color-report-format` | ターミナル | ○ | OSC 4/10/11 の色問い合わせに返す形式(`16-bit`、`8-bit`、`none`)。 |
| `vt-kam-allowed` | ターミナル | ○ | プログラムが KAM(ANSI モード 2)でキーボード入力を無効化することを許可するかどうか。 |
| `vt-window-resize-allowed` | ターミナル | ◎ | プログラムが xterm の `CSI 8 ; rows ; columns t` シーケンスでウィンドウサイズを変更することを許可するかどうか。 |
| `vt-xt-checksum-report` | ターミナル | ○ | プログラムが DECRQCRA で画面領域のチェックサムを要求することを許可するかどうか。 |
| `vt-xt-checksum-extension` | ターミナル | ○ | リセット後の DECRQCRA チェックサムの計算方法(xterm の `checksumExtension` 相当)。 |
| `custom-shader` | 描画 | ✕ | 既定のシェーダーの後に実行する、Shadertoy 互換の GLSL シェーダーのパス。 |
| `custom-shader-animation` | 描画 | ✕ | カスタムシェーダーのアニメーションループを動かす条件(フォーカス時、`always`、または無効)。 |
| `bell-features` | ベル | △ | ベルが鳴ったときの動作(`system`、`audio`、`attention`、`title`、`border` など)。 |
| `bell-audio-path` | ベル | ✕ | ベル機能 `audio` が有効なときに再生する音声ファイル。 |
| `bell-audio-volume` | ベル | ✕ | システム音量に対するベル音声ファイルの音量(0.0〜1.0)。 |
| `app-notifications` | GTK | - | 表示するアプリ内通知(トースト)の種類(`clipboard-copy`、`config-reload` など)。 |
| `macos-non-native-fullscreen` | macOS | - | macOS のフルスクリーンにネイティブ方式ではなく高速な非ネイティブ方式を使うかどうか。 |
| `macos-window-buttons` | macOS | - | macOS のタイトルバーのウィンドウボタン(信号機ボタン)を表示するかどうか。 |
| `macos-titlebar-style` | macOS | - | macOS のタイトルバーのスタイル(`native`、`transparent`、`tabs`、`hidden`)。 |
| `macos-titlebar-proxy-icon` | macOS | - | macOS のタイトルバーに作業ディレクトリのプロキシアイコンを表示するかどうか。 |
| `macos-dock-drop-behavior` | macOS | - | macOS の Dock アイコンにファイルをドロップしたときに新しいタブと新しいウィンドウのどちらで開くか。 |
| `macos-option-as-alt` | macOS | - | macOS の Option キーを Alt として扱うかどうか(左右どちらか一方のみも指定可)。 |
| `macos-window-shadow` | macOS | - | macOS のウィンドウに影を付けるかどうか。 |
| `macos-hidden` | macOS | - | macOS のアプリを Dock とアプリスイッチャーから隠すかどうか。 |
| `macos-auto-secure-input` | macOS | - | パスワード入力プロンプトを検出したときに macOS のセキュア入力を自動で有効にするかどうか。 |
| `macos-secure-input-indication` | macOS | - | macOS のセキュア入力が有効な間、画面上に表示を出すかどうか。 |
| `macos-applescript` | macOS | - | macOS で Ghostty の AppleScript 辞書を公開し処理するかどうか。 |
| `macos-icon` | macOS | - | Dock とアプリスイッチャーに表示する macOS のアプリアイコン(独自アイコンを含む)。 |
| `macos-custom-icon` | macOS | - | `macos-icon` が `custom` のときに使うアイコンファイルの絶対パス。 |
| `macos-icon-frame` | macOS | - | `custom-style` アイコンにおける macOS のアプリアイコンの枠の素材。 |
| `macos-icon-ghost-color` | macOS | - | `custom-style` アイコンにおける macOS のアプリアイコンのゴーストの色。 |
| `macos-icon-screen-color` | macOS | - | `custom-style` アイコンにおける macOS のアプリアイコンの画面部分のグラデーション色。 |
| `macos-shortcuts` | macOS | - | macOS のショートカットによる Ghostty の操作を許可するかどうか(`ask`、`allow`、`deny`)。 |
| `linux-cgroup` | Linux | - | Linux でリソース管理のため各サーフェスを個別の一時的な `systemd` スコープに入れるかどうか。 |
| `linux-cgroup-memory-limit` | Linux | - | 各ターミナルの cgroup に設定するメモリのソフト上限(バイト単位、`MemoryHigh`)。 |
| `linux-cgroup-processes-limit` | Linux | - | 各ターミナルの cgroup に設定するプロセス数の上限(`TasksMax`)。 |
| `linux-cgroup-hard-fail` | Linux | - | `systemd` スコープの作成に失敗したときにサーフェスの作成も失敗させるかどうか。 |
| `gtk-opengl-debug` | GTK | - | GTK の OpenGL デバッグログを有効にするかどうか。 |
| `gtk-single-instance` | GTK | - | GTK アプリを単一インスタンスで動かし、新たな起動を新しいウィンドウとして開くかどうか。 |
| `gtk-titlebar` | GTK | - | ウィンドウマネージャーのタイトルバーの代わりに GTK のタイトルバーを表示するかどうか。 |
| `gtk-tabs-location` | GTK | - | GTK のタブバーの位置(`top`、`bottom`、`hidden`)。 |
| `gtk-titlebar-hide-when-maximized` | GTK | - | ウィンドウの最大化中に GTK のタイトルバーを隠すかどうか。 |
| `gtk-toolbar-style` | GTK | - | GTK の上下のバーの外観(`flat`、`raised`、`raised-border`)。 |
| `gtk-titlebar-style` | GTK | - | GTK のタイトルバーのスタイル(`native`、またはタブバーを統合する `tabs`)。 |
| `gtk-wide-tabs` | GTK | - | GTK のタブを利用可能な幅いっぱいに広げるかどうか。 |
| `gtk-horizontal-tab-scroll` | GTK | - | タッチパッドの2本指による横スクロールで GTK のタブを切り替えるかどうか。 |
| `gtk-custom-css` | GTK | - | アプリの外観調整のために読み込む独自の GTK CSS ファイル。 |
| `desktop-notifications` | 通知 | ◎ | ターミナル内のアプリが OSC 9 や OSC 777 などのシーケンスでデスクトップ通知を出せるかどうか。 |
| `progress-style` | タスクバー | ◎ | ターミナル内のアプリが ConEmu の OSC 9;4 シーケンスでグラフィカルな進捗バーを表示できるかどうか。 |
| `bold-color` | 色 | ○ | 太字テキストに使う色(特定の色、または明るいパレットを使う `bright`)。 |
| `faint-opacity` | 色 | ○ | 淡色(faint)テキストの不透明度(0 が透明、1 が不透明)。 |
| `term` | ターミナル | ◎ | シェルに設定する環境変数 `TERM` の値。 |
| `enquiry-response` | ターミナル | ○ | 実行中のコマンドから `ENQ`(`0x05`)を受け取ったときに返す文字列。 |
| `async-backend` | Linux | - | Linux で非同期 IO やイベント処理に使う低レベル API(`auto`、`epoll`、`io_uring`)。 |
| `auto-update` | 更新 | - | macOS での自動更新の動作(`off`、`check`、`download`)。 |
| `auto-update-channel` | 更新 | - | 自動更新で使うリリースチャネル(`stable` または `tip`)。 |

凡例:

- ◎ Windows で使える。動作確認の記録がある。
- ○ Windows で使える(コードから判断)。動作確認の記録はない。
- △ 一部だけ使える。
- ✕ Windows では未実装。
- \- 対象外。macOS、GTK、Linux、X11、Wayland だけに関係する設定。
