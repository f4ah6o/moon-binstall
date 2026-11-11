# 0009: 導入済みツールの一覧と、不要になったreceiptの安全な整理を提供する

状態: proposal / open。実装・実行テストは未実行。
Priority: P2
Updated: 2026-10-13
Baseline: `5e9f36351bf2581a96d0a093f770f3134da325c6` (`main`)

## 目的と根拠

何をどこから導入したか、手動変更/削除で記録が古くなっていないかを確認できるようにする。cargo-binstallの `--list` / `--prune` が対応機能。ただしCargoの他installerの記録は扱わず、MoonBit版receiptに限定する。

現行 `receipt.mbt` は個別receiptの読書きを実装するが、一覧CLIはない。`parse_batch_options` はcoordinateを必須とする。archiveの `asset_digest` と実行ファイルの `binary_digest` が異なる既存設計を維持する。

## 実装範囲と契約

1. coordinate不要の `--list` と `--prune` を追加し、相互排他とする。`--bin-dir` > `MOON_BINSTALL_DIR` > `$HOME/.local/bin` を利用し、自己更新用の実行中binary探索は行わない。install用option/coordinateとの混在はエラー。`--dry-run` はpruneとだけ組み合わせる。
2. 対象directory直下の `.moon-binstall-receipts/*.json` のみ読む。network、PATH全体探索、binary起動、再帰走査はしない。directory不在は空一覧・成功で、新規作成しない。最大10,000件、1receipt 64KiBを上限として超過は明示エラーにする。
3. schema version、必須field、digest形式、安全なbinary名、filenameとbinaryの一致、destinationが指定bin directory内の期待pathに一致することを検証する。未知schemaは推測で既存schemaとして扱わない。symlinkや非regular entryは辿らない。
4. 状態は `installed`（実fileとbinary_digest一致）、`modified`（不一致）、`missing`、`invalid`（不正schema）、`unsupported`（未知schema）、`unsafe`（symlink等）、`unreadable`。source/package/tag/target/destinationと観測状態をbinary名順で表示する。receiptのない実行ファイルを管理済みと推定しない。
5. `--list` は一切変更しない。missing/modifiedは観測結果として終了0、invalid/unsupported/unsafe/unreadableや走査上限は確認できた結果を示して終了1とする。欠損と読取失敗を混同しない。
6. `--prune` が削除するのは、schemaとpathを検証できたreceiptのうちmissing/modifiedのものだけ。実行ファイルの削除・置換・chmodは絶対に行わない。invalid/unsupported/unsafe/unreadableがあれば最初の削除前に中止する。
7. 実pruneは0006の排他取得後に再走査し、削除直前もentry/binary状態を再確認する。dry-runは削除予定を表示するだけでロックファイルも作らない。削除済み件数と失敗を区別し、途中失敗を全体rollback成功とは表示しない。
8. 0008が提供する `--json-output` に `inventory`、`prune_planned`、`pruned` eventを追加する。summaryには各状態数、pruned/prune_planned件数を明示し、未知状態をinstalledにまとめない。

## 受入条件

- [ ] installed/modified/missingをraw・zip・tgz由来のfixtureで正しく分類する。
- [ ] 読み取りにasset_digestでなくbinary_digestを使用し、実行ファイルを起動しない。
- [ ] 不在directoryのlist/prune dry-runでdirectoryを新規作成しない。
- [ ] 外部path入りreceipt、symlink、未知schema、壊れたJSON、permission failureを誤ってpruneしない。
- [ ] prune前後で全実行ファイルの内容/mtime/permissionが不変で、対象receiptだけが消える。
- [ ] installとpruneの並行実行を排他し、新しく書かれた正当なreceiptを古い判断で削除しない。

## 検証計画

未実行。`inventory_wbtest.mbt` の一時filesystem fixtureで全状態を検証する。CLI subprocessでtext/JSON、終了コード、dry-run無変更、10,000件/64KiB境界を確認する。並行テストは0006のbarrier fixtureを再利用する。

実装はroot package内の `inventory.mbt` 等に分離し、新規自動化は `.mbtx`。`///|`、checked errorsを用い、`moon check --target native --deny-warn`、`moon test --target native`、`moon fmt`、`moon info --target native` を実行する。

## 関連と対象外

0001で作ったreceiptの利用機能であり更新判定の作り直しではない。実pruneは0006、JSON対応は0008に依存する。uninstall、全ツール一括更新、未管理binaryの採用、外部package managerとの統合、壊れたreceiptの推測修復は対象外。

## 参照

- [現行receipt model](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/receipt.mbt)
- [現行CLI parser](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/installer.mbt)
- [cargo-binstall HELP: list/prune](https://github.com/cargo-bins/cargo-binstall/blob/3be4ad2b146f3302f92e5956c54fedbb6ae8cccc/HELP.md)
- [MoonBit agent guide](https://github.com/moonbitlang/skills/blob/8b9f1bad14bc62560dbe3537855379e561a4e066/skills/moonbit-agent-guide/SKILL.md)
