# 0002: coordinate の名称と解決先を説明し、正しい指定へ案内する

状態: proposal / open。実装・実行テストは未実行。
Updated: 2026-10-11
Baseline: `0e4e087506ff6711c431f3bea646186ecb3ada2b` (`main`)
観測対象: macOS Apple Silicon / moon-binstall v0.1.6 / dsh v0.1.16

## 目的

repository 名、Mooncakes module 名、実行名の違いを利用者が推理しなくても、正しい binary install coordinate を選べるようにする。

## 観測事実

1. 利用者は `f4ah6o/dsh` を指定し、`https://api.github.com/repos/f4ah6o/dsh/releases/latest` に対する curl exit 56 を受けた。その後 `f4ah6o/dsh.mbt` では dsh v0.1.16 の導入に成功した。
2. [spec.mbt](../../spec.mbt) は2成分を GitHub repository、3成分以上を Mooncakes module 内 package と解釈する。`f4ah6o/dsh` は module lookup ではなく repository lookup に進む。
3. dsh v0.1.16 の README は `moon binstall dsh` を案内するが、[本リポジトリの README](../../README.md) は短縮名を拒否する仕様を記載している。

curl exit 56 の原因は未確定である。このログを HTTP 404 / repository 不在の証拠に使わない。

## 実装範囲

1. ヘルプの最初に、binary install の具体例と2成分 / 3成分の意味を示す。`.mbt` を含む実際の GitHub repository 名を入力する必要があることを説明する。
2. resolution 表示に利用者の入力、選択した source、repository / module-package、tag / version、binary、target を示す。GitHub 解決を Mooncakes 解決と誤認できる表示にしない。
3. `dsh` のような短縮名の構文拒否は、完全 coordinate の形式とコピー可能な例を返す。例は実在する対応 repository から選ぶ。
4. 有効な2成分指定への失敗時は、まず source を明示する。HTTP 404 が確認できたときだけ「この repository または release を確認できない」と案内する。transport failure で名称違いと断定しない。
5. `.mbt` 付き repository への候補提示を行うなら、元の指定の404と候補 repository / matching release を確認した read-only 情報だけを使う。候補を利用者に示しても、別 coordinate へ自動切替・自動インストールしない。
6. README / ヘルプの例を対応仕様と照合し、source install の module 名を GitHub binary install の例に流用しない。

最初の increment は説明・resolution 表示・入力支援を完成させる。短縮名 alias registry、2成分指定の意味変更、`.mbt` の無条件補完は追加しない。

## 受入条件

- [ ] `moon binstall --help` の冒頭で `moon binstall f4ah6o/dsh.mbt` の形式と解決 source を確認できる。
- [ ] `f4ah6o/dsh.mbt` と `f4ah6o/dsh/cmd/dsh@VERSION` の違いをヘルプで説明する。
- [ ] 短縮名 `dsh` を渡すと、内部 Failure を読まずに完全指定の例へ進める。
- [ ] transport failure を repository 不在や名称違いとして表示しない。
- [ ] 名称候補を表示する場合、404・候補存在・release の検証結果が fixture で裏付けられ、別 repository を黙って install しない。
- [ ] resolution / README / ヘルプで coordinate、binary 名、target の説明が一致する。
- [ ] 既存の explicit coordinate、`@tag`、Mooncakes package、`--module` の解決が変わらない。

## 検証計画

未実行。[spec_wbtest.mbt](../../spec_wbtest.mbt) の coordinate regression と、[installer_wbtest.mbt](../../installer_wbtest.mbt) の既存 transport seam による404・通信失敗・候補あり/なしの fixture を実施する。ヘルプ / resolution は意味のある断片を CLI smoke で確認する。

## 関連と境界

- [0003: エラー分類と表示](0003-actionable-install-errors.md) が transport / HTTP error の分類を担当する。この issue は source / 名称の説明を担当する。
- dsh 側の `issues/open/0005-installation-and-first-run-guide.md` で README の非対応 `moon binstall dsh` を修正する。installer が既に対応している正しい full coordinate を案内するため、alias の実装を待つ必要はない。
