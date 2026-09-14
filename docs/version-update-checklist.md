# Ghostty バージョン更新チェックリスト

この文書は、このフォークでGhostty本体のバージョンを変更するときに、更新箇所と
検証手順を漏らさないためのチェックリストです。Windows版の配布準備を主対象と
しますが、既存のupstreamのビルド規則も維持します。

## 1. 現在のバージョン経路

| 場所 | 役割 | 通常の更新 |
|---|---|---|
| `build.zig.zon` の `.version` | Gitチェックアウトで使うGhostty本体の基準バージョン | **必要** |
| Gitのブランチ名、コミットハッシュ、タグ | 通常ビルドのpre-release/buildメタデータ | 自動 |
| `-Dversion-string=X.Y.Z` | CIまたは明示的な検証で基準バージョンを上書き | 条件付き |
| ソースtarball内の `VERSION` | Git情報のない配布ソースで使うバージョン | `zig build dist` が生成 |
| `build.zig` の `lib_version` | `libghostty-vt` の独立したバージョン | ライブラリをリリースするときだけ |
| `src/build/WindowsVersionResource.zig` | Windowsリソース用ヘッダーをビルド時に生成 | 自動 |
| `dist/windows/ghostty.rc` | Windowsファイルプロパティへ生成値を埋め込む | 通常は変更不要 |

通常のGitチェックアウトには `VERSION` を置かない。存在すると
`build.zig.zon` より優先されるため、手作業で作成・更新しない。

`pkg/*/build.zig.zon` の `.version` は各依存コンポーネントのバージョンであり、
Ghostty本体のバージョン更新では変更しない。

## 2. 更新前

- [ ] 対象がGhostty本体、`libghostty-vt`、または両方のどれかを決める。
- [ ] 新しい値がSemantic Versioning形式であることを確認する。
- [ ] `git status --short` で既存の作業を確認し、無関係な変更を混ぜない。
- [ ] `VERSION` がリポジトリ直下に残っていないことを確認する。

```powershell
Test-Path -LiteralPath VERSION
git status --short
```

## 3. Ghostty本体の更新

- [ ] `build.zig.zon` の `.version` を更新する。
- [ ] 開発ブランチの `.version` は、対象リリース系列を示す `X.Y.Z-dev` とする。
- [ ] 正式版を検証するときの `-Dversion-string`、またはタグは、pre-releaseを
  含まない `X.Y.Z`、`vX.Y.Z` とする。
- [ ] 既存タグからビルドする場合は、タグ `vX.Y.Z` と
  `build.zig.zon` のmajor、minor、patchが一致することを確認する。
- [ ] Windows版の変更内容と既知の制限が `docs/windows.md` および
  `docs/windows-roadmap.md` と一致していることを確認する。

通常ビルドでは、`build.zig.zon` のmajor、minor、patchへGitのブランチ名と
短縮コミットハッシュが付加される。たとえば `windows` ブランチの開発ビルドは
`X.Y.Z-windows-+abcdef0` の形式になる。

## 4. 条件付きの更新

### libghostty-vtも更新する場合

- [ ] `build.zig` の `lib_version` を更新する。
- [ ] `-Demit-lib-vt` のビルドと対象テストを実行する。
- [ ] Ghostty本体だけの更新では `lib_version` を変更していないことを確認する。

### ソースtarballを作成する場合

- [ ] パッケージ作成が依頼で明示されていることを確認する。
- [ ] `zig build dist` が生成したtarball内の `VERSION` を確認する。
- [ ] 作業ツリーへ `VERSION` をコピーまたはコミットしない。

### タグまたは公開操作を行う場合

- [ ] コミット、タグ、push、公開の各操作が依頼で明示されていることを確認する。
- [ ] タグ名を `vX.Y.Z` とする。
- [ ] `.github/workflows/release-tag.yml` へ渡るバージョンとタグが一致することを
  確認する。
- [ ] 公開前に署名、配布形式、対象アーキテクチャを別途確認する。

## 5. Windows版の検証

バージョンを明示したReleaseビルドは、アーカイブやインストーラーを作らずに
次のコマンドで検証できる。

```powershell
./scripts/build-release.ps1 `
    -AdditionalZigArgs '-Dversion-string=X.Y.Z'

./zig-out/release/bin/ghostty.exe --version
./zig-out/release/bin/ghostty.exe +list-keybinds --default
```

- [ ] Releaseビルドが成功する。
- [ ] `ghostty.exe --version` が意図した `X.Y.Z` を表示する。
- [ ] `+list-keybinds --default` が終了コード0で完了する。
- [ ] ReleaseスクリプトがPE形式、CPU、GUIサブシステム、必須リソースを
  正常と判定する。
- [ ] Release実行ファイルを起動し、端末表示と基本入力を実機確認する。
- [ ] `Get-AuthenticodeSignature` で署名状態を確認する。
- [ ] `git diff --check` が成功する。

## 6. Windowsファイルプロパティの確認

`src/build/WindowsVersionResource.zig` はGhosttyのビルドバージョンからヘッダーを
生成し、`dist/windows/ghostty.rc` がWindowsの版情報へ埋め込む。

- 数値版はWindowsの4要素へ `major.minor.patch.0` として格納する。
- `FileVersion` と `ProductVersion` はpre-releaseとbuild metadataを含む完全な
  Semantic Versionを保持する。
- Debugビルドでは `VS_FF_DEBUG` を設定し、Releaseビルドでは解除する。
- major、minor、patchのいずれかが16ビット上限を超える場合はビルドを失敗させる。

バージョン更新後は、CLI表示とは別にWindows APIからも値を確認する。

```powershell
$info = (Get-Item -LiteralPath `
    './zig-out/release/bin/ghostty.exe').VersionInfo
$info.FileVersion
$info.ProductVersion
```

- [ ] `FileVersion` と `ProductVersion` が空ではない。
- [ ] 両方のmajor、minor、patchが `ghostty.exe --version` と一致する。
- [ ] Releaseビルドの `IsDebug` が `False` である。
- [ ] 数値版の第4要素が `0` である。

## 7. 更新後

- [ ] 変更したファイルを一覧にして、意図した範囲だけであることを確認する。
- [ ] バージョン、コミットハッシュ、ビルド方式、署名状態を検証記録へ残す。
- [ ] 既知の制限を利用者向け文書へ反映する。
- [ ] コミットやpushは、明示的に依頼された場合だけ実施する。
