# 0005: GitHub認証を送信先に束縛し、認証が必要なReleaseを導入する

状態: proposal / open。実装・実行テストは未実行。
Priority: P1
Updated: 2026-10-13
Baseline: `5e9f36351bf2581a96d0a093f770f3134da325c6` (`main`)

## 目的と根拠

CIで明示的に渡したGitHubトークンを利用し、公開APIの匿名アクセス制限とprivate Releaseの取得に対応する。cargo-binstallのトークン対応を移植するが、他アプリの資格情報の自動探索は持ち込まない。

現行 `installer.mbt` の `fetch_text` はAccept/User-Agentのみ、`download` はURLから取得する。CLIに認証設定はなく、`ResolvedInstallPlan` に認証用asset IDもない。既存のHTTPエラー分類は再実装せず利用する。これは静的確認であり、実private repositoryでの失敗再現ではない。

## 実装範囲と契約

1. 空でない `GITHUB_TOKEN`、次に `GH_TOKEN` を採用する。両方未設定なら現在の匿名動作を維持する。`--no-github-token` は両方を無効化する。制御文字を含む値は通信前に拒否し、トークンそのものは表示しない。
2. 認証はCLIで選択・検証したrepositoryの `https://api.github.com:443` のRelease APIに限定する。Mooncakes、download.mooncakes.io、browser_download_url、任意URLにAuthorizationを付けない。URLのuserinfo、別port、hostの部分一致は許可しない。
3. 認証ありのasset取得は、検証済みReleaseに所属するasset IDからAPI URLを組み立て、`Accept: application/octet-stream` で取得する。直接200と302の両方を扱う。既存のrepository/tag/nameとSHA-256の照合を残し、API URLを信頼しただけで導入しない。
4. redirectは各hopを検査する。別originにはAuthorizationを転送せず、HTTPS限定・最大5回を維持する。認証を再付与できるのは元の許可されたAPI resourceのみとし、別repositoryへのredirectには付与しない。署名付きCDN URLのqueryはログやreceiptに残さない。
5. トークンをargv、例外、debug/JSON出力、receiptに含めない。curlにはstdin/pipe、またはprivate directory内の0600 header fileで渡す。file使用時は正常終了・例外処理時に削除し、強制終了で残る可能性を権限制限と手動削除案内で扱う。認証要求ではcurlの既定設定を無効化し、`--location-trusted` 等で境界を変更されないようにする。
6. 401、403、429、404を既存stageで分類する。404を「確実に不存在」と断定せず権限不足の可能性も案内し、認証失敗を匿名再試行や別repositoryへの自動切替で隠さない。`contents: read` と対象repositoryへのアクセス権を案内する。
7. `ReleaseAsset` 等の公開structを不用意に変更せず、asset IDと認証設定は内部plan/transportに保持する。公開entry pointでも同じ送信先検査を通す。

## 受入条件

- [ ] token優先順位、未設定、明示無効化、制御文字の拒否が決定的に確認できる。
- [ ] public匿名導入と、認証APIからの200/302 asset導入が独立に成功する。
- [ ] 送信記録上、Mooncakes・CDN・別port・別repositoryにAuthorizationが渡らない。
- [ ] tokenを含む入力で失敗させてもargv、stdout/stderr、debug、receiptに秘密値がない。
- [ ] 401/403/404/429、digest不一致、redirect超過ではbinaryとreceiptを変更しない。
- [ ] `--dry-run` は認証して解決できるが、binary/receiptを書き換えない。

## 検証計画

未実行。`github_auth_wbtest.mbt` にtoken選択・URL境界・redirect状態遷移の表駆動テストを追加する。既存 `FixtureTransport` に送信記録を追加し、CLI subprocessではcurl代替fixtureでargv・header fileのpermission/cleanupを検査する。実private Releaseは秘密を記録しないopt-in smokeとして分離する。

実装はroot package内の小さな `.mbt` に分離し、`///|` とchecked errorsを使用する。新規テスト用自動化は `.mbtx` とし、`moon check --target native --deny-warn`、`moon test --target native`、`moon fmt`、`moon info --target native` を実行して公開API差分を確認する。

## 関連と対象外

0003のエラー分類の上に認証を追加する。GitHub Enterprise、git-credentials/gh設定の探索、token保存、任意asset host、無制限再試行は対象外。0007の署名asset取得も本transportを使う。

## 参照

- [現行transport](https://github.com/f4ah6o/moon-binstall/blob/5e9f36351bf2581a96d0a093f770f3134da325c6/installer.mbt)
- [cargo-binstall HELP: GitHub token](https://github.com/cargo-bins/cargo-binstall/blob/3be4ad2b146f3302f92e5956c54fedbb6ae8cccc/HELP.md)
- [GitHub: Get a release asset](https://docs.github.com/en/rest/releases/assets#get-a-release-asset)
- [MoonBit agent guide](https://github.com/moonbitlang/skills/blob/8b9f1bad14bc62560dbe3537855379e561a4e066/skills/moonbit-agent-guide/SKILL.md)
