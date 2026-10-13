# 0007: Minisign署名を検証し、署名必須ポリシーで導入できるようにする

状態: proposal / open。実装・実行テストは未実行。
Priority: P1
Updated: 2026-10-13
Baseline: `5e9f36351bf2581a96d0a093f770f3134da325c6` (`main`)

## 目的と根拠

SHA-256による配布物一致の検証に、選択した公開鍵による署名検証を重ねる。cargo-binstallのMinisignと `--only-signed` が対応機能。署名は安全なプログラムである保証でも、GitHub/Mooncakes自体の侵害に対する万能な対策でもない。

現行 `ArtifactConfigSet` / `ArtifactOverride` にsigning情報はなく、`stage_install` はdigest検証後に展開する。既存source checksum、asset_digest、binary_digestは役割を変えず残す。

## 実装範囲と契約

1. `moon-binstall.json` のpackageに `signing` objectを追加する。必須は `algorithm: "minisign"` と `pubkey`、任意の `file` は署名URL templateとし、既定 `{url}.sig` とする。初期版の変数は `{url}` のみ。未知algorithm、空/不正鍵、未知fieldは解決時に拒否する。
2. target overrideではsigning object全体の置換のみ許可する。省略はpackage値を継承する。部分的なkey/fileの混合や `null` による検証無効化は許さない。未選択overrideも構文検証する。
3. 鍵の出所はchecksum確認後のMooncakes source内manifest、または利用者が明示したlocal manifestに限定する。取得したRelease本文や隣接 `.pub` を自動で信頼しない。既存CLI契約上、local manifestはMooncakes coordinate用。直接GitHub coordinateで信頼済みsigning metadataがない場合、`--only-signed` は拒否する。
4. signingありなら既定で検証必須、なしなら従来のdigest検証で導入可能とする。`--only-signed` はbatchの全itemにsigningを要求する。`--force` / `--skip-compat-check` は署名検証を無効化しない。`--skip-signatures` は追加しない。
5. 署名assetも選択済みrepository/tag内のRelease assetに限定し、有効なGitHub digestを要求する。最大64KiB。アーカイブ展開前に、ダウンロードした配布物そのもののbytesを検証する。抽出後binaryを署名対象にすり替えない。
6. 初期verifierは外部 `minisign` を引数分離したprocess APIで呼び出す。暗号を独自実装しない。modern formatのみを受け入れ、鍵/署名はprivate stagingで扱う。検証が必要なのにverifier不在なら導入前に明確なエラーとする。unsigned導入にはこの依存を要求しない。
7. 既存receiptは署名検証の証拠ではない。同一digestでskipできる場合も、signingあり/署名必須なら取得・署名検証を通してからskipする。既存の管理済みbinary/receiptの内容とmtimeは変えない。receipt不在の移行では検証成功後にだけ新規receiptを付与できる。鍵変更や署名欠落を古いreceiptで回避しない。
8. `--dry-run` は署名の要求と鍵の出所を表示するだけで「検証済み」と表示しない。署名失敗は既存 `digest` stageの署名検証operationとして示し、別target/unsignedへのfallbackをしない。

## 受入条件

- [ ] 有効署名はraw/zip/tgzで成功し、asset/binaryのdigestが従来どおり別管理される。
- [ ] 署名欠落、改変asset、別鍵、legacy署名、不正metadata、過大署名は書換え前に失敗する。
- [ ] unsignedの従来動作は維持され、`--only-signed` を付けたunsigned itemは拒否される。
- [ ] 同一版の再導入でも署名を再検証し、失敗したbatchは最初のbinary置換前に停止する。
- [ ] `--force` と `--skip-compat-check` を併用しても署名不一致を回避できない。
- [ ] ダウンロードした実行ファイルは検証・比較のために起動されない。

## 検証計画

未実行。`signing_wbtest.mbt` のmetadata/ポリシーテストと、固定の公開テスト鍵・署名・改変fixtureを使うnative統合テストを追加する。fixture生成は `.mbtx` からminisignを呼ぶ。CIに署名用依存を明示し、秘密のproduction鍵やlive networkを必須にしない。

root packageにverifier adapterを分離し、`///|`、checked errorsを使用する。`moon check --target native --deny-warn`、`moon test --target native`、`moon fmt`、`moon info --target native` と公開API差分確認を行う。

## 関連と対象外

private署名assetには0005の認証transportを使用する。鍵配布経路自体の侵害、TOFU/自動鍵更新、Sigstore/GPG、外部署名host、署名だけでSHA-256を省略する動作は対象外。

## 参照

- [現行artifact metadata](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/artifact.mbt)
- [cargo-binstall SIGNING](https://github.com/cargo-bins/cargo-binstall/blob/3be4ad2b146f3302f92e5956c54fedbb6ae8cccc/SIGNING.md)
- [cargo-binstall HELP](https://github.com/cargo-bins/cargo-binstall/blob/3be4ad2b146f3302f92e5956c54fedbb6ae8cccc/HELP.md)
- [MoonBit agent guide](https://github.com/moonbitlang/skills/blob/8b9f1bad14bc62560dbe3537855379e561a4e066/skills/moonbit-agent-guide/SKILL.md)
