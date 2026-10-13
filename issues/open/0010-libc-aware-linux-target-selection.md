# 0010: Linuxのgnu/muslを区別し、互換候補を明示的に選べるようにする

状態: proposal / open。実装・実行テストは未実行。
Priority: P2
Updated: 2026-10-13
Baseline: `5e9f36351bf2581a96d0a093f770f3134da325c6` (`main`)

## 目的と根拠

同じLinux/CPU向けのgnu版とmusl版を区別して配布・選択できるようにする。cargo-binstallのtarget候補選択はglibc Linuxでgnu→musl、musl環境ではgnuを候補外とする。

現行 `validate_target` はOS/CPUの4名称のみを受け付ける。`resolve_asset_plan_for_release` は対象assetを選択した後、`check_declared_glibc` と静的ELF検査で実行互換性を確認する。libc検査がないのではなく、libc別assetの選択表現が不足している。

## 実装範囲と契約

1. `linux-x86_64-gnu`、`linux-x86_64-musl`、`linux-aarch64-gnu`、`linux-aarch64-musl` を追加する。既存の4名称と既定選択は維持する。従来の `linux-x86_64` 等を暗黙にgnuと再定義しない。
2. 新名称を `--target`、順序付き `--targets`、manifestのexact-target override、asset名生成、receipt、表示に通す。既存targetを記録したreceiptは読み続ける。別target identityへの通常更新は既存どおり拒否し、明示的 `--force` を必要とする。
3. opt-inの `--prefer-compatible-targets` を追加し、`--target` / `--targets` と排他にする。hostと同じCPUだけを候補にし、glibcはgnu→legacy→musl、muslはmusl→legacy、libc不明はlegacyのみとする。macOSでは現在のhost targetだけを使う。host検出はgnu/muslを示す明確な根拠を必要とし、数字が読めるだけの応答をglibcと推定しない。
4. legacy候補のABIは不明として扱う。musl hostでlegacyに `glibc-min` がある場合や、glibc hostで宣言最小版を満たせない場合は、その既知の非互換を理由に候補を除外できる。候補metadata・URL・digestの形式検査を先に行い、不正metadataを非互換やasset不在に読み替えない。
5. GNU/muslという名称だけで実行可能と断言しない。最終候補には従来のdigest、archive、PT_INTERP/shared-library/symbol-version検査を行う。post-downloadでの互換失敗、digest/署名不一致では他候補へfallbackしない。`--skip-compat-check` は既存の互換検査だけを迂回し、検証やhost検出を偽装しない。
6. `{target-libc}` は新しい明示targetだけで `gnu` / `musl` に展開する。legacy/macOSでは不明としてtemplateエラーにし、guessしない。他の既存template変数は新targetを正しくOS/CPUに分解する。
7. CLI override > exact-target override > package defaultの既存優先順位を保つ。除外したtargetと理由、最終選択をdry-run/JSONに表示する。候補なしは導入前に明確に失敗する。
8. 本issueはresolverの対応であり、musl assetの新規ビルド・公開を実施済みと扱わない。選択機能が使えるのはpublisherが一致するdigest付きassetを配布した場合に限る。

## 受入条件

- [ ] flagなしの既存4target/asset優先順位/receipt動作に回帰がない。
- [ ] gnu/muslの両CPUについて明示targetとmanifest overrideを解決できる。
- [ ] glibc・musl・libc不明・macOSで候補順が契約どおりで、別CPUを自動選択しない。
- [ ] glibc-min不一致だけの候補は安全に除外でき、不正digest/metadataは即時失敗する。
- [ ] PT_INTERP等の検査は新targetでも動作し、muslという名前だけでPASS扱いしない。
- [ ] 旧receiptのtargetを勝手に書換えず、同名別targetへの置換保護を維持する。

## 検証計画

未実行。host能力を注入する `target_selection_wbtest.mbt` を追加し、metadata/asset候補とELF fixtureを表駆動で組み合わせる。ネットワークや実hostのlibcに依存しないテストと、glibc Linux/musl Linux/macOSの実環境smokeを分離する。

root package内のtarget modelを小さな `.mbt` に分離し、`///|`、checked errorsを用いる。新規自動化は `.mbtx`。`moon check --target native --deny-warn`、`moon test --target native`、`moon fmt`、`moon info --target native` で公開API差分も確認する。

## 関連と対象外

既存のordered targets/ELF互換検査を置き換えず拡張する。Windows、Rust triple完全互換、Cargo cfg式、muslの静的リンク保証、エミュレーション、source build fallback、release workflowの変更は対象外。

## 参照

- [現行target選択とlibc/ELF検査](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/installer.mbt)
- [現行artifact template](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/artifact.mbt)
- [cargo-binstall HELP: targets](https://github.com/cargo-bins/cargo-binstall/blob/3be4ad2b146f3302f92e5956c54fedbb6ae8cccc/HELP.md)
- [cargo-binstall SUPPORT: target-libc](https://github.com/cargo-bins/cargo-binstall/blob/3be4ad2b146f3302f92e5956c54fedbb6ae8cccc/SUPPORT.md)
- [MoonBit agent guide](https://github.com/moonbitlang/skills/blob/8b9f1bad14bc62560dbe3537855379e561a4e066/skills/moonbit-agent-guide/SKILL.md)
