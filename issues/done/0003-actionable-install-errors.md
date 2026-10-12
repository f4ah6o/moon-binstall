# 0003: install エラーを分類し、場所・原因・対処を表示する

状態: proposal / open。実装・実行テストは未実行。
Updated: 2026-10-11
Baseline: `0e4e087506ff6711c431f3bea646186ecb3ada2b` (`main`)
観測対象: macOS Apple Silicon / moon-binstall v0.1.6

## 目的

利用者が内部 source location や curl 数値を調べなくても、失敗した操作と次の対処を判断できるようにする。未確定の原因を repository 不在等と誤って説明しない。

## 観測事実と原因

ログの主メッセージは次の形式になっている。

```text
moon-binstall: Failure(installer.mbt:... FAILED: already exists: ... (use --force to replace))
moon-binstall: Failure(installer.mbt:... FAILED: HTTPS request failed (curl exit 56): https://api.github.com/repos/f4ah6o/dsh/releases/latest)
```

[main.mbt](../../main.mbt) は捕捉した error をそのまま補間して表示する。[installer.mbt](../../installer.mbt) の `fetch_text` は取得失敗を curl exit と URL の文字列へ変換する。HTTP status と transport failure の分類、操作 context、利用者向け rendering を明示する必要がある。

今回の curl exit 56 の根本原因はログだけでは未確定。通信受信失敗の分類はできても、HTTP 404 や名前違いを事実として表示してはいけない。

## 実装範囲

1. coordinate / argument、repository / release / asset、transport / HTTP、digest、archive、destination、runtime compatibility の主要エラーを分類し、stage と対象を保持する。
2. curl の bounded result から取得できた HTTP status と transport exit を別に保持する。API の確定404、429、403、5xx、status 未取得の通信失敗を区別する。既存 resolver が使う「この tag が見つからない」等の制御フローを維持する。
3. 短い stderr に「操作・対象」「観測できた理由」「実行可能な次の対処」を出す。source file / line / MoonBit Failure wrapper を通常表示に含めない。
4. 操作に応じて対処を変える。destination 衝突は対象と explicit replacement、missing release は coordinate / tag 確認、transport は接続確認と再試行、digest / malformed archive はその asset を導入しなかったことを示す。
5. HTTP 403 を一律 rate limit と呼ばない。rate-limit header 等で判別できる場合のみ説明し、理由が未取得なら403として表示する。
6. stable error code と詳細診断を opt-in の debug 表示に残す。HTTP headers、credential、response body の無制限出力はしない。
7. 失敗は通常の非ゼロ exit、stderr へ出す。stdout の成功表示と分離し、batch ではどの coordinate / stage が失敗したか分かるようにする。

自動 retry policy の追加や、失敗を別 repository / source build へ自動 fallback することはこの increment に含めない。

## 受入条件

- [ ] 通常表示に `Failure(installer.mbt:...)` がなく、対象・観測理由・対処が揃っている。
- [ ] status 未取得の curl exit 56 は通信失敗であり、repository 不在・404 と誤表示しない。
- [ ] API 404 は repository / release を確認できないと表示し、GitHub が隠す private / unauthorized の区別を推測しない。
- [ ] 403、429、5xx は確認できた status / header に従って分類される。
- [ ] release / asset 不足、checksum failure、archive 不正、destination 衝突、互換性不一致の表示と exit を検証する。
- [ ] 失敗時の diagnostics が stderr にあり、debug を除く stdout に raw exception / body を出さない。
- [ ] bounded metadata / transfer、HTTPS-only、checksum 検証が regression しない。
- [ ] debug でも credential を出さず、通常表示から省いた診断情報を必要な範囲で取得できる。

## 検証計画

未実行。[installer_wbtest.mbt](../../installer_wbtest.mbt) の transport fixture を拡張し、status 未取得・404・403・429・5xx と local filesystem failure を決定的に再現する。pure classifier に加え CLI subprocess の stderr / stdout / exit を確認する。curl exit 56 の実環境での根本原因調査は、この分類テストが通ったこととは区別して記録する。

## 関連と境界

- [0001: 再導入・更新](0001-idempotent-install-and-managed-update.md) が destination 衝突時の install policy を変更する。
- [0002: coordinate 案内](0002-coordinate-discovery-and-guidance.md) が syntax error / 名称確認の具体例を提供する。
- [0004: PATH と自己更新](0004-effective-path-and-self-update.md) の警告も同じ出力方針を使うが、完了した install を PATH warning だけで失敗扱いにしない。
