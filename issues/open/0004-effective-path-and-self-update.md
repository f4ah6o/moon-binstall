# 0004: 有効な実行パスを表示し、自己更新で別コピーを作らない

状態: proposal / open。実装・実行テストは未実行。
Updated: 2026-10-11
Baseline: `0e4e087506ff6711c431f3bea646186ecb3ada2b` (`main`)
観測対象: macOS Apple Silicon / moon-binstall v0.1.6

## 目的

「Installed と出たが、次に起動されるのは古い別コピー」という状態を見つけられるようにする。moon-binstall 自身の更新先を、利用者の明示指定と現在の実行パスに整合させる。

## 観測事実と未確認事項

[README](../../README.md) の bootstrap は `$HOME/.moon/bin/moon-binstall` に導入する。一方、通常の binary install の既定先は `$HOME/.local/bin` で、利用者の自己更新ログも後者へ導入している。

両方にファイルがある場合、PATH の順序で更新対象と次回実行対象が違う可能性がある。ただし利用者ログには `command -v` 等の結果がないため、二重配置・旧版起動が実際に発生したとは断定しない。

## 実装範囲と優先順位

1. 一般 package の既定先 `$HOME/.local/bin` は維持する。destination は `--bin-dir`、`MOON_BINSTALL_DIR`、既定値の順で選び、成功表示にどの指定が効いたかを含める。
2. installer 自身の coordinate と現在の実行 executable identity が一致し、明示 destination 指定がない自己更新では、現在実行中の regular executable の実体を更新先候補にする。`argv[0]` が bare name のときは PATH から、絶対 / 相対 path のときは呼び出し元 cwd を使って確認する。
3. 自己更新対象が symlink / 非 regular、実行パスが特定不能、identity が曖昧な場合は黙って別 directory に導入しない。確認できた状態と明示 `--bin-dir` の案内を返す。既存の symlink 拒否を迂回しない。
4. 更新可否は [0001](0001-idempotent-install-and-managed-update.md) の同一内容 / 管理済み更新 / explicit force policy を使う。未管理旧版の初回更新まで無条件に置換する仕様にはしない。
5. 完了時に destination、candidate version、PATH から次回解決される executable を表示する。destination が PATH にない / 別コピーが優先なら、完了済み install と PATH warning を区別して stderr に出す。
6. PATH の診断で他の executable を実行しない。見つかった別コピーの version は未確認として扱い、更新版と同じと推測しない。
7. 次の確認操作として `command -v moon-binstall`、`type -a moon-binstall`、`moon binstall --version` 等を案内する。必要な PATH 修正例は空白や引用符を含む directory でも shell-safe に示す。
8. シェル設定や他のコピーを自動編集 / 削除しない。shell の command cache が次回選択に影響する場合があることは確認手順で扱い、単純な PATH 計算を実行済み確認と表現しない。

## 受入条件

- [ ] `--bin-dir` が環境変数より優先し、環境変数が既定値より優先することを表示と実ファイルで確認する。
- [ ] `~/.moon/bin` から自己更新した場合、明示 override がなければその regular file を更新先候補にする。
- [ ] 明示 directory に自己導入した場合は指定先を尊重し、別コピーが優先するなら警告する。
- [ ] PATH にない destination / shadowed destination を判別し、install 自体の成功は成功として保持する。
- [ ] 相対 / bare executable path、空白入り directory、PATH の空要素・relative 要素を現実の解決規則に従って扱う。
- [ ] symlink / 不明 identity の自己更新で保護を迂回せず、対象未確定のまま別コピーを作らない。
- [ ] `--dry-run` は更新予定先と PATH 診断を表示し、既存 binary / receipt を変更しない。
- [ ] version 確認のために downloaded / 別コピーの executable を実行しない。
- [ ] 別 directory にある既存コピーと shell 設定を変更しない。

## 検証計画

未実行。[installer_wbtest.mbt](../../installer_wbtest.mbt) に HOME / PATH / invocation path / directory override の fixture を追加する。実行されたら marker を残す偽 executable を使い、診断中に起動しないことを確認する。macOS opt-in smoke は2つの bin directory を持つ一時 HOME と専用 shell を使い、自己更新後の実行パス・version を実際に確認する。通常の利用者環境を変更して再現しない。

## 関連と境界

- 0001 が更新内容・ownership を担当し、この issue は対象 path と導入完了診断を担当する。
- [0003: エラー表示](0003-actionable-install-errors.md) と warning / stderr の形式を揃える。
- 汎用インストーラーへの dsh 固有の起動手順埋込み、Dsh.app 導入、既定 directory の全面変更は対象外。
