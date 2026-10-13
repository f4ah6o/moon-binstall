# 0006: 同じ導入先への並行実行を排他し、binaryとreceiptの競合を防ぐ

状態: proposal / open。実装・実行テストは未実行。
Priority: P1
Updated: 2026-10-13
Baseline: `5e9f36351bf2581a96d0a093f770f3134da325c6` (`main`)

## 目的と根拠

同じ導入先で複数のmoon-binstallが動いても、古い状態に基づく置換や別実行のreceipt上書きを起こさない。cargo-binstallは通常の追跡機能で並行実行を保護し、`--no-track` がその保護を無効化すると説明している。

現行 `install_many_using` は `decide_install`、staging、binary rename、`record_install_receipt` を順に実行するが、これらを囲むプロセス間ロックがない。`write_receipt` のatomic renameは単一ファイルの保護であり、この区間全体の排他ではない。競合は静的分析上の懸念で、実行再現は未実施。

## 実装範囲と契約

1. 実際に選ばれたbin directoryを基準に、通常install・自己更新・`install_from_asset_file` を同じ排他に参加させる。相対表記や親directoryのaliasで同じ実体を別ロックにしない。
2. 安全に開いた `.moon-binstall.lock` にOSのadvisory exclusive lockを取得する。symlink/非regular fileを拒否し、ロックファイルは0600で作る。inodeを差し替えたり、解放時にunlinkしたりしない。macOSで外部 `flock` コマンドの存在を前提にしない。
3. Release解決はロック前でよいが、最終的な `decide_install` と既存binary/receiptの再読込は取得後に行う。staging、最終destination再検査、binary置換、receipt保存、既存binaryへのreceipt付与までロックを保持する。
4. `--lock-timeout SECONDS` を追加し、既定30秒、0は即時判定とする。負数・非整数・上限3600秒超は引数エラー。待機中は導入先を変更しない。timeoutは既存 `filesystem` stageで場所・競合・再試行方法を示す。
5. 通常終了・例外ではdescriptorを閉じ、プロセス終了でもOSが解放する方式を使う。PIDファイルの存在だけで所有判定せず、古そうなロックを推測で削除しない。
6. `--dry-run` はロックファイルや導入先を新規作成しない。読み取り時点のplanであり、並行変更に対する予約ではないと明記する。0009の実pruneは同じ排他に参加する。
7. binary rename後・receipt保存前の終了を全体atomicと称しない。不一致は既存digest照合で検出し、自動的に管理済み/同一版と誤認しない。batch全体のrollbackや外部の非協調writer対策は別課題とする。

## 受入条件

- [ ] 同じdestinationの2プロセスは直列化され、後続は取得後の最新binary/receiptから再判定する。
- [ ] 別destinationの2プロセスは互いに待たない。自己更新と通常導入の同一先は競合する。
- [ ] timeoutでは当該実行によるbinary/receipt変更がない。既存ロックファイルは削除しない。
- [ ] 保持プロセス終了後に次の実行が取得でき、rename途中で終了した不整合を誤ってskipしない。
- [ ] lock symlink、非regular entry、permission failureを安全に拒否する。
- [ ] `--dry-run` の前後でdirectory・binary・receipt・lockの新規作成/mtime変更がない。

## 検証計画

未実行。`install_lock_wbtest.mbt` と `.mbtx` の2プロセスfixtureを追加する。順序はpipe/markerの明示barrierで制御し、固定sleepだけに依存しない。異なるversion、同一version、異なるpackageの同名binary、lock timeout、保持者終了、receipt保存直前の中断をLinux/macOSで検証する。

root packageに小さなlock abstractionを追加し、APIが不足する場合のみ狭いnative bindingを用意する。`///|`、checked errors、必要なprivateテストと公開APIのblack-boxテストを使う。`moon check --target native --deny-warn`、`moon test --target native`、`moon fmt`、`moon info --target native` を実行する。

## 関連と対象外

[0001](../done/0001-idempotent-install-and-managed-update.md) の更新/不整合検出を再実装する課題ではなく、協調する複数プロセス間の排他を追加する。NFS等のremote filesystem、batch rollback、ロック強制解除、`--force` による排他無視は対象外。

## 参照

- [現行install pipeline](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/installer.mbt)
- [現行receipt保存](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/receipt.mbt)
- [cargo-binstall HELP: no-track](https://github.com/cargo-bins/cargo-binstall/blob/3be4ad2b146f3302f92e5956c54fedbb6ae8cccc/HELP.md)
- [MoonBit agent guide](https://github.com/moonbitlang/skills/blob/8b9f1bad14bc62560dbe3537855379e561a4e066/skills/moonbit-agent-guide/SKILL.md)
