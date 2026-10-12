# 0001: 同一バイナリの再導入をスキップし、管理済みツールを更新できるようにする

状態: proposal / open。実装・実行テストは未実行。
Updated: 2026-10-11
Baseline: `0e4e087506ff6711c431f3bea646186ecb3ada2b` (`main`)
観測対象: macOS Apple Silicon / moon-binstall v0.1.6

## 目的

同じ install コマンドの繰り返しを通常操作として扱う。再導入の度に `already exists` と `--force` を経由せず、現在と候補の状態を判断できるようにする。

## 観測事実と原因

利用者は `moon binstall f4ah6o/moon-binstall` を実行し、v0.1.6 の解決後に既存 `$HOME/.local/bin/moon-binstall` で失敗した。`--force` を付けて再実行すると導入に成功した。

既存ファイルのバージョンはログにないため、同一版だったとは断定しない。[installer.mbt](../../installer.mbt) の `check_destination` は既存 regular file を force なしで一律拒否する。比較・管理済み更新の分岐が必要になる。

## 実装範囲と契約

1. GitHub digest を検証済みの候補と、既存 regular file の SHA-256 を比較する。同一内容なら `Already installed` と解決 version / destination を表示して終了コード 0、書換えなしとする。version を調べるために候補や既存 executable を実行しない。
2. install receipt を導入し、coordinate の出所、package / binary、target、tag / version、検証済み digest、destination を記録する。receipt は registry / GitHub の解決・検証結果に基づく。receipt があるだけで現存ファイルを信頼せず、保存 digest と実ファイルを照合する。
3. 同一 identity の管理済みファイルが保存 digest と一致し、新しい版の候補が検証できた場合、同じ install コマンドで `--force` なしに更新する。既存版と候補版を表示する。
4. 未管理の異なる内容、手動変更、別 package の同名 binary、比較不能な tag、downgrade は自動置換しない。理由と、確認後に使う既存 `--force` の手順を表示する。SemVer のみ大小比較し、任意 tag の新旧を推測しない。
5. 既存 receipt がない現行ユーザーも、候補と digest が完全一致すればスキップできる。旧版の異なる内容を更新する初回だけは確認済み `--force` を使い、その後を管理済み更新にする。
6. binary / receipt の更新順・中断復旧を設計する。両者の不一致を次回に検出し、誤った `Already installed` や管理済み判定をしない。
7. `--dry-run` は proposed action と destination を示すが、binary / receipt を変更しない。`--force` は再導入・明示置換として残す。

既存の digest verification、非 regular / symlink 拒否、検証後の staging / rename を維持する。batch は全候補の検証と置換可否判定を済ませてから書換えを始める。この提案で既存の batch を全体 atomic と称することはしない。

## 受入条件

- [ ] 同じ検証済み binary の2回目の install は終了コード 0、内容・mtime の書換えなしでスキップする。
- [ ] 管理済み旧版の更新は新旧 version を示し、通常 install で成功する。
- [ ] 未管理・手動変更・別 identity・downgrade は force なしで元ファイルを保持する。
- [ ] 既存 version 不明を推測で表示しない。receipt のない同一候補の移行が成立する。
- [ ] checksum failure、receipt 不一致、途中失敗で未検証バイナリを利用可能状態にしない。
- [ ] `--dry-run` は binary / receipt とも書換えない。
- [ ] 混在 batch の検証 / destination 判定失敗は最初の置換前に検出される。
- [ ] 比較のために executable を起動しないことを fixture で確認する。

## 検証計画

未実行。[installer_wbtest.mbt](../../installer_wbtest.mbt) に一時 destination・偽 release metadata・検証済み fixture を使う同一版 / 旧版 / 未管理 / 手動変更 / 中断ケースを追加する。stdout と終了コードは CLI subprocess smoke で確認する。実 GitHub release の自己更新は別の opt-in macOS smoke として結果を記録する。

## 関連と境界

[0004: PATH と自己更新](0004-effective-path-and-self-update.md) が「どの executable を更新するか」を担当し、この issue は選んだ destination をどう扱うかを担当する。任意 executable の起動による version 検出、source build fallback、symlink の force 置換は対象外。
