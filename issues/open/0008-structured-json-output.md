# 0008: 導入結果と失敗をバージョン付きJSON Linesで出力する

状態: proposal / open。実装・実行テストは未実行。
Priority: P2
Updated: 2026-10-13
Baseline: `5e9f36351bf2581a96d0a093f770f3134da325c6` (`main`)

## 目的と根拠

CIやagentが表示文の正規表現解析に依存せず、解決・導入・skip・失敗を識別できるようにする。cargo-binstallには `--json-output` がある。本提案のschemaはMoonBit版独自であり、upstreamのJSON互換を称しない。

現行 `install_many_using` / `report_path_diagnostics` は直接println/eprintlnし、`report_error` はstage付きの複数行textを出力する。既存の `stage_code` と `InstallError` を再利用する。

## 実装範囲と契約

1. opt-inの `--json-output` を追加する。既定のtext表示・終了コードは変更しない。有効時のstdoutは1行1JSON objectのJSON Linesのみとし、通常の診断もevent化する。debug有効でも非JSONやraw例外をstdoutに混在させない。
2. 全eventに `schema_version: 1`、1から単調増加する `sequence`、`event` を持たせる。item eventには `coordinate`、`binary`、`target`、`tag`、`destination` を既知の範囲で入れ、未解決はnullとする。versionの意味をtool versionと混同しない。
3. 初期eventは `resolved`、`planned`、`installed`、`updated`、`skipped`、`warning`、`error`、`summary`、`help`、`version`。導入結果はbinary置換とreceipt保存の完了後にのみ出す。`--dry-run` はplannedでありinstalledではない。API宣言digestと実測検証済みdigestを別fieldにする。
4. errorには既存stage文字列の `code` と `operation`、`target`、`reason`、`action` を入れる。ここでerror.targetは操作対象であり、item.targetのplatformとは別のnested objectにする。未知の内部errorは秘匿情報を除いた `internal` codeにする。
5. 制御できる通常終了ではsummaryをちょうど1回、最後に出す。`status` は `completed` / `failed`、`exit_code`、installed/updated/skipped/planned/failed/not_processedの件数を持つ。途中のfilesystem失敗で先行itemが導入済みなら、その事実を残しbatch全体atomicと表示しない。receipt保存失敗等の途中変更は `partial: true` も記録する。
6. 引数エラーやhelp/versionも、認識された `--json-output` の下ではJSONで返す。別optionの値に含まれる同じ文字列をflagと誤認しない。process killやstdout破断ではsummary到達を保証せず、stdout書込失敗は非0終了とする。
7. token、Authorization、署名付きURL query、制御文字を秘匿/正しくescapeする。stdout/stderrの通常経路とdebug経路を同じredactionに通す。messageの文字列は安定APIとせず、field/code/eventの互換性を保証する。

## 受入条件

- [ ] 成功、更新、skip、dry-run、PATH warning、引数エラーの全stdout行がJSONとしてparseできる。
- [ ] schema_version、sequence、最終summaryの一意性と件数が実際のファイル状態に一致する。
- [ ] quote、改行、日本語を含むpath/理由でも不正JSONや行分割が生じない。
- [ ] digest失敗とrename/receipt失敗を区別し、未実施itemやpartial変更を成功扱いしない。
- [ ] token入りのfixtureとdebug有効時にも秘密値を出力しない。
- [ ] flagなしの既存text CLI smokeが回帰しない。

## 検証計画

未実行。内部event/sinkを `output.mbt` に分離し、`output_wbtest.mbt` でschemaとredactionを検証する。CLI subprocessのJSON Linesをparseしてevent順・件数・終了コード・ファイル状態を照合する。動的path等はfixtureで正規化し、snapshotの更新で失敗を隠さない。

新規自動化は `.mbtx`。`///|`、checked errors、公開APIのblack-box/docテストを使用し、`moon check --target native --deny-warn`、`moon test --target native`、`moon fmt`、`moon info --target native` を実行する。

## 関連と対象外

0003のtextエラー改善とは別の出力modeで、stage分類を共有する。0009はこのschemaにinventory/prune eventを追加する。自動再試行、daemon、remote telemetry、source build fallback、upstream JSON schemaの完全互換は対象外。

## 参照

- [現行出力とinstall pipeline](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/installer.mbt)
- [現行error model](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/errors.mbt)
- [cargo-binstall HELP: json-output](https://github.com/cargo-bins/cargo-binstall/blob/3be4ad2b146f3302f92e5956c54fedbb6ae8cccc/HELP.md)
- [MoonBit agent guide](https://github.com/moonbitlang/skills/blob/8b9f1bad14bc62560dbe3537855379e561a4e066/skills/moonbit-agent-guide/SKILL.md)
