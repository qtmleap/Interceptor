# Plugin, JavaScript and Webhook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 特定のリクエスト／レスポンスを契機にJavaScriptプラグインを実行し、利用者が承認した外部Webhookへ自動送信できるようにする。

**Architecture:** Mudmouthの転送境界から上限付き不変イベントを取得し、PacketTunnelの専用ワーカーへ渡す。ローカルSwift Packageで権限、QuickJS、暗号化Outbox、native送信を分離し、appは設定・編集・dry-run・履歴を担当する。

**Tech Stack:** Swift / SwiftUI、iOS 17、SwiftNIOを使う既存Mudmouth、QuickJS（先行検証必須）、SQLite3、CryptoKit、Network.framework、既存Runestone。

**Spec:** [設計仕様](../specs/2026-10-15-plugin-automation-design.md)

**Release order（2026-10-16）:** 次の通常更新はレイアウト・導線とSSL Proxying Listの操作改善。以下のスクリプト／プラグイン機能は次のメジャーアップデートで実装する。プラグインの主な追加導線は、公開リポジトリの登録→配布スクリプトの選択→内容・権限確認→追加（無効状態）とする。リポジトリ配布は今回追加された要件で、従来のレビュー記録だけで詳細設計済みと扱わない。

通常更新の同意画面は初回・設定の本文とレイアウトまで共通化し、撤回ボタンを中央に配置し、内容に合う幅と左右の余白を確保する。使い方とCapture Setupも入口と画面を統合し、明示的な開始後に同じシート内で設定する。[PR #17](https://github.com/qtmleap/Interceptor/pull/17)のTestFlight 1.0.1（34）は2026-10-16に内部配布を確認済み。出荷app SHAは`6c3b8cc2a802ddb5f4555229603821c9ddd9d334`、Mudmouthは`be4cc787669fdfebead90aba197a3501ebdd0063`。メジャー更新開始時にはその後のdevelopとの差分を確認する。新しいPAC経路の今回の実機確認は未実施。

2026-10-16の要望により、XXXL専用対応・追加検証は必須条件から外し、通常の文字サイズを優先する。

## Global Constraints

- 本書作成ではプロダクトコードを変更しない。実装・外部送信・公開は別の実行段階。
- 調査時のapp SHA: `18c2ff9ae38ab0cdfe02a88946526702b45f7b49`。Mudmouth SHA: `be4cc787669fdfebead90aba197a3501ebdd0063`。実装開始時は先行する通常更新を含む最新developへ基準を更新し、正確なapp/Mudmouth SHAを記録する。SSL Proxying Listなど先行更新済みの部分は再利用し、Task 2等で古い固定設定へ戻さない。
- app/extはiOS 17.0を維持。既存XCTest最低OS18.5、既存CIはXcode 27。新規純粋コアのMacテストはmacOS 14以降。
- 共有App Groupは `group.jp.qleap.intrcptr`。既存SwiftDataのRecordスキーマとトークンの旧Keychain移行を巻き込まない。
- request/response両方、実JavaScript、公開リポジトリからのスクリプト追加、Files import、画面が閉じた状態での自動Webhookを含めて完了とする。
- 次期メジャーの実装前に、配布一覧の形式・対応リポジトリサービス・取得元とリビジョンの固定・更新確認を詳細設計して独立レビューする。リポジトリ読み込みは実行や権限付与、キャプチャ対象追加を行わず、任意のネイティブプラグインは受け付けない。G0の公開条件確認にもリポジトリ経由のスクリプト配布を含める。
- 転送処理にJS・DNS・SQLite・送信・無制限Taskを置かない。既定の機能OFF、権限追加／revision更新は再許諾。
- 予算・phase・retry等は設計仕様5〜9節の値をそのまま使用し、変更は仕様とテストを同時にレビューする。
- en/ja、iPhone/iPad、Light/Dark、標準文字サイズを対象とし、文言・fixture・機能名を汎用ツールとして記述する。
- Git操作前はAGENTS.mdのgh-commit-identityを読み、native checkerとguarded Gitを使用する。下記commit messageは候補であり、認証・Author/Committer検証を省略しない。
- Simulatorを使う検証は事前にhost/device-set/既存UDID・windowを記録し、起動前にfinally/終了シグナルのcleanupを登録する。この実行が作成／起動したものだけを終了・削除する。
- public APIのみ。JavaScriptCoreのSPIや署名・審査・既存リリースワークフローの迂回を採用しない。
- appは1本の統合branchで進め、途中のタスクをdevelopへ個別マージして未完成版を自動配信しない。Mudmouth側のeventsとconsent v2を初回の1変更セットとして公開する。後続の修正も別途レビュー・公開・全pin更新・影響テストを行い、最終実機証跡と出荷ビルドを最後の固定SHAへ揃える。

## Review Focus

1. 返答しないサーバー、100/103、pipelining、SSE、途中切断でも正しいphaseとexchangeへ対応付ける。Task 2のテストで固定する。
2. 無限ループ、巨大allocation、regex、getter/toJSON、深いJSONがnativeの転送やUIを占有しない。Task 0/4で測定する。
3. 送信許可発行と撤回・編集・クラッシュの競合で旧権限のjobが再開しない。Task 5/7で競合を制御して検証する。
4. URLの秘密、DNS rebinding、IPv4-mapped IPv6、redirect、自己キャプチャにより許可外の相手へ送らない。Task 6/9で検証する。
5. app/extの同時アクセス、起動後のロック、OS停止、容量不足で重複・情報残存・トンネル停止を隠さない。Task 5/7/9で検証する。

---

## 実装単位と依存順

Task 0 → Task 1 → Task 2/3 → Task 4/5/6 → Task 7 → Task 8 → Task 9。

Task 2はMudmouthを担当するworkerへ、Task 3〜6は新規packageの担当へ分けられる。インターフェースをTask 1で固定し、同じファイルを同時に編集させない。Task 7の統合と実機・UI検証はCodexが責任を持つ。小さな独立タスクは適切なSonnet/Thinking、審査・実行制御をまたぐ難しいレビューのみPro/Opusを選ぶ。

### テスト環境を区別する

| 環境 | 実行対象／証明できる範囲 |
|---|---|
| Mac SwiftPM | schema、matcher、JS、SQLite競合、retry判断、transport fixture。実VPNは証明しない |
| iOS Simulator | app UI、DIしたworkerの状態遷移、in-process MITMのloopback通信。NEPacketTunnelProviderは動作したと扱わない |
| 署名した物理iPhone/iPad | 実トンネル、app停止・画面lock・回線変更、共有Keychain、実ルーティング、CPU/RSS。A3/A4/A5/A8/A9の最終合格はこの証拠が必須 |

helperのCLIは `--mode simulator --device iphone|ipad --appearance light|dark --only-test ...` と `--mode physical --udid UDID --artifact-dir PATH` に分ける。physicalでは通常署名、利用者が承認・設定したCA/VPN、所有するfixture endpointを用い、devicectl/xcodebuildとdevice consoleのログをMacで収集する。Linux reviewerは実行したと主張しない。iOS17製品スモークは既存XCTest最低18.5を流用せず、手動または専用の17対応harnessで行う。端末モデル・実OS・UDID・署名をG1出力に記録し、検証機材がなければ未実施とする。

| 配置 | 責務 |
|---|---|
| Mudmouth/Sources/Mudmouth/CaptureEvents/ | HTTP phaseの組み立て、不変イベント、上限付きmirror |
| Interceptor/Packages/InterceptorAutomation/Sources/AutomationCore/ | schema、matcher、projection、grant、ActionIntent |
| 同 Sources/CQuickJS/、Sources/AutomationRuntime/ | 固定版Cランタイム、Swift実行器 |
| 同 Sources/AutomationStorage/ | SQLite、暗号化Outbox、Keychain |
| 同 Sources/AutomationTransport/ | 宛先/DNS/IP/TLS/POST、retry判断 |
| 同 Tests/ | コア・ランタイム・storage・transportの独立テスト |
| PacketTunnel/AutomationWorker.swift | パッケージとMudmouthの橋渡し、唯一のsender、lifecycle |
| Interceptor/Automation/AutomationController.swift | UI用snapshot、設定・許諾・dry-runとprovider message |
| リポジトリ取得サービス（Task 0で配置・型を確定） | 配布一覧の取得・検証、取得元とrevisionの固定、選択・更新差分。Viewや実行器から分離 |
| Interceptor/Views/Automation/ | 一覧、エディタ、許諾、endpoint、履歴 |
| InterceptorTests/Automation*Tests.swift | app/extの統合、既存機能の回帰 |
| InterceptorUITests/AutomationUITests.swift | 新UIの独立クラス。既存巨大クラスへ追加しない |

## Task 0: 公開条件と組み込み可能性を先行確認する

**Files:** Create `docs/automation/release-gates.md`、`docs/automation/runtime-evaluation.md`、`scripts/automation-verify.py`、`Packages/InterceptorAutomation/Package.swift`の最小骨格とCQuickJS/runtime/transportスパイク用tests。Task 1はこの骨格を拡張する。
**Produces:** G0（公開条件）の記録、G1（中断・メモリ）の測定、G2（接続先固定・TLS・自己キャプチャ回避）の測定。未成立は不成立として記録する。

- [ ] 先行する通常更新の出荷SHAを確認して実装基準を更新し、変更済みのキャプチャ先設定と本計画の差分を整理する。
- [ ] `docs/automation/repository-distribution-design.md`へ、対応サービス・配布一覧・取得元／revisionの固定・不正データ／取得失敗・更新確認を詳細設計し、独立レビューする。配布項目は既存の単一JSON packageへ変換する。取得・解析サービスの型と配置、fixture、Task 1/8への依存をここで確定し、UIに通信処理を持ち込まない。
- [ ] 現行の公開Policy・同意文・ASC説明と設計仕様11節を比較し、Appleへの確認事項を公開リポジトリ由来の第三者スクリプト／データ項目／受信先／コード形式まで具体化する。問い合わせ文の作成までと、実際の送付・回答取得を区別して記録する。
- [ ] 開発用スパイクを公開する構成と混在させず、QuickJS公式2026-06-04の配布SHA-256/LICENSEを記録してapp/extへ静的リンクする最小試験を作る。全製品実装へ進む前に測定結果をレビューする。
- [ ] `testInterruptsInfiniteLoop`、`testCapsHeapAndStack`、`testInterruptsRegexAndToJSON`を先に書く。50 ms予算、150 ms以内の回収、heap 8 MiB、stack 256 KiBを超える入力を用いる。
- [ ] hostnameと接続IPを分離したNetwork.framework試験を書く。`testPinnedPublicAddressWithOriginalHostnameTLS`、`testRejectsRebindingAndBadCertificate`、`testDeliveryDoesNotReenterMITM`を通す。DNSの事前検査だけで合格にしない。
- [ ] DNSServiceGetAddrInfo + DNSServiceSetDispatchQueueで非同期解決を試し、system resolver、3秒以内のDNS、IPv6-only/DNS64 prefix、回線変更、cancelとref解放を確認する。G2へOSの実際のDNS経路とトンネルへ再流入しない証拠を残す。
- [ ] scripts/automation-verify.pyにowned deviceの準備・xcodebuild・ログ・finally cleanupを実装する。既存ci-simulator-start-worker.py/cleanup.pyの責務を保ち、共有runnerを止めない。
- [ ] 最低対応の実機を含むiPhone/iPadで負荷を測り、追加RSS 16 MiB以下を目標に確認する。JS内intrinsicも止まらなければ採用を保留し、仕様へ戻す。foreground専用や制限なしJSCへ変更しない。
- [ ] 評価結果、選択理由、未解決のApple判断、出荷フラグの扱いを記録する。G0未解決のビルドを公開しない。Commit候補: `docs(automation): record runtime and release gates`。

## Task 1: 型・予算・設定の基盤を固定する

**Files:** Create `Packages/InterceptorAutomation/Package.swift`、`Sources/AutomationCore/{AutomationEvent,PluginManifest,PluginPackage,Grant,ActionIntent,AutomationLimits}.swift`、`Tests/AutomationCoreTests/SchemaTests.swift`。
**Interfaces:**
- UUIDをPluginID/RevisionID/EndpointID/EventID/DeliveryIDに使い、取り違えをwrapper型で防ぐ。
- `AutomationEvent: Sendable, Codable`: id、exchangeID、phase、capturedAt、request metadata、optional response metadata、bounded body、bodyState。
- `PluginPackage(manifest: PluginManifest, source: String)`、`PluginRevision(id: RevisionID, digest: SHA256Digest)`。
- `JSONValue: Sendable, Codable`はnull/bool/finite number/string/array/objectのみ。
- `PluginResult(actions: [ActionIntent])`、`ActionIntent.webhook(endpointId: EndpointID, json: JSONValue)`。
- `PluginConfig(values: JSONValue, endpoints: [String: EndpointID])`、`Grant`は仕様7節のrevision/scope/epochを保持する。
- `ProjectedEvent(json: JSONValue, binding: EndpointID, grantRevision: UUID)`はEventProjectionだけが生成し、Runtimeはraw AutomationEventを受け取れない。ProjectedEventの内部initializerに限定する。
- Coreで `CancellationToken: @unchecked Sendable`（NSLockでcancel()/isCancelledを保護）、`AuthorizedWebhookRequest(deliveryID:endpointID:endpointRevision:payloadBytes:grantEpoch:)`、`EndpointCredential(url:headers:)`、`DeliveryOutcome`を定義する。
- target graphは仕様4節に従う。Storageの `LeasedDelivery` はlease情報とCoreのrequestを包み、Transportへはrequestだけ渡す。CSQLiteはSDK sqlite3.hを公開するsystem library target。

- [ ] `testSchemaRoundTrip`（4phaseとoptional response）、`testRejectsUnsupportedSchemaAndOversizeImport`（256/128 KiB）、`testRejectsInvalidIDsAndNonfiniteJSON`を書く。
- [ ] `swift test --package-path Packages/InterceptorAutomation --filter SchemaTests`を実行し、型未実装によるFAILを確認する。
- [ ] 上記型と仕様9節の定数、canonical manifest+sourceのrevision digestを実装する。schemaVersionは1、未知field/versionの扱いは明示エラーとする。
- [ ] 同じコマンドをPASSさせ、app/ext双方のpackage product参照をproject.pbxprojへ追加し、OS floorとstrict concurrencyを確認する。
- [ ] Commit候補: `feat(automation): define plugin and event contracts`。

## Task 2: HTTPフックとキャプチャ先の単一化

**Files:** Mudmouth Create `Sources/Mudmouth/CaptureEvents/{CapturedHTTPEvent,CaptureEventSink,CaptureEventAssembler}.swift`。Modify `Handlers/ProxyHandler.swift`、`Handlers/ConnectHandler.swift`、`Actions/MITM.swift`、`Classes/CaptureAuthorization.swift`。App Create `InterceptorTests/AutomationCaptureTests.swift`、`Interceptor/Automation/CaptureTargetStore.swift`。Modify `Tuberose.swift`、`ServerListView.swift`、`PacketTunnelProvider.swift`。
**Interfaces:**
- Mudmouth: `CaptureEventSink: Sendable`の `offer(_ event: CapturedHTTPEvent) -> Bool`。
- `MITM.startTunnel(options: [String:NSObject]? = nil, eventSink: (any CaptureEventSink)? = nil) async throws`。
- `CaptureTargetSnapshot(revision: UUID, hosts: [CanonicalHost])`。同じsnapshotをProxyOption/CONNECT/matchDomainsへ使う。
- PacketTunnel側でCapturedHTTPEvent→AutomationEventを対応付ける。bodyStateと重複headerを失わない。

- [ ] `testRequestCompletesBeforeAnyResponse`、`testFourPhasesAndStableExchange`、`testInformationalResponseDoesNotConsumeRequest`、`testPipeliningChunkedHeadAndDisconnect`を書く。既存InterceptorTests.swiftも使用する@testable MudmouthとDebugのtesting設定を明示的に維持し、in-process loopback fixtureから実際のProxyHandlerを通す。Simulatorで実VPNを起動しない。
- [ ] `testSSETriggersHeadersWithoutWaitingForEnd`、`testUpgradeStopsHTTPBodyEvents`、`testMirrorCapAndGzipBomb`、`testFullSinkDoesNotDelayForwarding`、`testOneTargetSnapshotUsedEverywhere`、`testHostMismatchAndSubdomainsReceiveNoGrant`、`testUnapprovedSubdomainRelaysTLSWithoutCapture`も書き、現状でFAILすることを確認する。
- [ ] head/endで不変snapshotを作る。encoded/decoded32 KiB、headers/path8 KiBを適用し、gzip展開は専用workerへ渡す。既存body getterをイベント経路で呼ばない。保存・通知成功をイベント条件にしない。
- [ ] 実機baselineで既存Recordの無制限body保持が転送安定性を破る場合、保持上限とtruncated表示の互換変更をこのタスク内の別レビュー単位として先に行う。旧token fixtureと履歴表示が壊れないことを固定する。
- [ ] 既存host設定を保持して単一storeへ移行する。host変更は差分確認と再接続で反映し、plugin importにhost追加の副作用を持たせない。
- [ ] MudmouthのCaptureAuthorization.version=2もこの変更セットへ含める。appの文言と移行はTask 7/8で対応し、最終app PR完成前に配信しない。
- [ ] `python3 scripts/automation-verify.py --mode simulator --device iphone --only-test InterceptorTests/AutomationCaptureTests`をPASSさせる。実トンネルのイベントはTask 9で実機再確認し、失敗時もowned simulator cleanupを確認する。
- [ ] 初回の依存公開前はapp PRを作成せず、既存XCLocalSwiftPackageReferenceの../Mudmouthを変更セットのcheckoutにしてローカルXcode Debugで両repoを検証する。リリースguardやCI pinは無効化しない。初回Mudmouth公開と4か所の実SHA固定後にapp PRを開き、branch CIは公開済み固定版で動かす。後続の依存修正は新レビュー・新commit・全pin更新を行い、関連するCI/実機の証跡を更新する。app_contract_test.rbの期待が固定値を持つか確認し、必要な契約だけを更新する。Commit候補: `feat(capture): publish bounded HTTP lifecycle events`。

## Task 3: プラグイン読み込み・条件・権限projection

**Files:** Create `Sources/AutomationCore/{PluginValidator,RuleMatcher,EventProjection,ActionValidator}.swift`、`Tests/AutomationCoreTests/{PluginValidatorTests,RuleMatcherTests,EventProjectionTests}.swift`。
**Consumes:** Task 1の型。**Produces:** `validate(package: PluginPackage) throws -> ValidatedPlugin`、`matches(event: AutomationEvent, subscription: Subscription) -> Bool`、`project(event: AutomationEvent, grant: Grant) throws -> ProjectedEvent`、`validate(result: PluginResult, grant: Grant, limits: AutomationLimits) throws -> [ValidatedAction]`。

- [ ] schema/size/UUID重複・更新競合、host canonicalization、encoded path、status、phaseの表形式テストを書く。
- [ ] `testDefaultProjectionOmitsPathQueryHeadersAndBody`、`testAllowedJSONPointersAndHeaderNamesOnly`、`testRawGrantIsExplicitExportPermission`、`testTruncatedJSONCannotMatchCompleteBodyRule`を書く。入力の秘密を出力に出さないassertを置く。
- [ ] `testDestinationSpecificProjectionCannotCombineGrants`とrequest phaseでstatus条件を拒否するtestを追加する。同じpluginでもendpointごとに別invocationとし、config.endpointsは1件だけにする。
- [ ] `testHeaderPhaseRejectsBodyRead`でheaders購読とjsonPointers/rawの組合せを拒否し、`testQueryProjectionUsesExchangeRequest`でresponse側からの許諾済みquery参照も固定する。
- [ ] `swift test --package-path Packages/InterceptorAutomation --filter AutomationCoreTests`でFAILを確認してから実装する。
- [ ] 任意native regexを導入せず、仕様5節の条件と仕様7節の事前projectionを実装する。出力のEndpointID、action最大2、深さ32/32 KiBを再検証する。
- [ ] テストをPASSさせ、import/updateで既定無効・旧grant失効となることを確認する。Commit候補: `feat(automation): validate plugins and data grants`。

## Task 4: JavaScript実行器

**Files:** Modify Task 0の `Sources/CQuickJS/`。Create `Sources/AutomationRuntime/{ScriptExecutor,QuickJSBridge,PluginInvocation}.swift`、`Tests/AutomationRuntimeTests/PluginRuntimeTests.swift`。
**Consumes:** ValidatedPlugin、ProjectedEvent、PluginConfig。**Produces:** `ScriptExecutor.run(plugin: ValidatedPlugin, event: ProjectedEvent, config: PluginConfig, cancellation: CancellationToken) async throws -> PluginResult`。C callback userdataはdeadlineとtokenを保持するInvocationStateで、VM破棄まで寿命を保証する。

- [ ] `testRunsRealOnRequestAndOnResponse`で実際のJSによる条件・整形・EndpointIDを検証する。
- [ ] Task 0の攻撃入力に加え、`testBudgetIncludesTopLevelGettersAndSerialization`、`testRejectsPromisesCyclesAndInvalidResult`、`testNoFetchFileObjCOrModuleLoader`、`testFreshRuntimeHasNoPriorGlobals`を書く。
- [ ] `swift test --package-path Packages/InterceptorAutomation --filter PluginRuntimeTests`でFAILを確認する。
- [ ] C/Swiftの所有権を明示し、deadline/heap/stackを設定して専用直列Queueで実行する。compile/eval/handler/result変換/解放までを計測する。JS例外にソース行を付け、永続ログに生のイベント・任意JS文字列を保存しない。
- [ ] handlerのobject返値はVM内の予算が効いている間に検証・JSON化し、C/Swift境界は長さ確認済みprimitive文字列だけにする。任意objectのgetter/Proxy/toJSONや例外toStringをnative側で予算外に呼ばない。source行取得も同じ境界で扱う。
- [ ] `testAggregateCpuBudgetAndFairScheduling`を追加し、100 ms/秒・burst100 msとround-robin、5秒を超えた待機eventの失効をdispatcherで検証する。
- [ ] malformed source、allocation、BigInt/regex/toJSONの負荷で回収できること、キャンセル後のVM解放、10,000回繰り返しのメモリ増加を測定してPASSさせる。
- [ ] QuickJSのLICENSEをLicenses画面に含める。Commit候補: `feat(automation): execute bounded JavaScript plugins`。

## Task 5: 共有設定・Keychain・失効・Outbox

**Files:** Create `Sources/AutomationStorage/{AutomationStore,SchemaMigrations,GrantStore,OutboxStore,SharedKeychain,PayloadCipher}.swift`、`Tests/AutomationStorageTests/{OutboxTests,RevocationTests,MigrationTests}.swift`。既存entitlementsと署名／IPA契約は読み、必要のない変更をしない。
**Interfaces:**
- `AutomationStore.open(directory: URL) throws`: SQLite WAL、既存Mudmouth.sqliteとは別DB。
- `GrantStore.revoke(scope:) throws -> RevocationReceipt`: epoch更新とpending無効化を一つの短いtransactionで実行。
- `OutboxStore.enqueue(actions:event:grant:) throws` / `claim(owner:now:) throws -> LeasedDelivery?` / `complete(lease:outcome:) throws`。
- `SharedKeychain`にendpoint全URL/認証とgrant暗号鍵を保存。既存App Group `group.jp.qleap.intrcptr` をkSecAttrAccessGroupへ明示し、専用service、AfterFirstUnlockThisDeviceOnly、synchronizable=falseでapp/ext共有を実機検証する。

- [ ] 2接続SQLiteの並行テストを書き、unique deliveryID、owner lease、crash後の回復、5試行/15分TTL、256件/8 MiB、disk full、migration失敗をassertする。
- [ ] `testRevocationWinsAgainstNewSendPermit`、`testEditedRevisionCancelsOldJobs`、`testKeyUnavailableAfterBootDefersDelivery`、`testPayloadNotPresentInDatabaseWalOrLogs`、`testExpiredPayloadAndGrantKeyAreRemoved`を書く。
- [ ] storageテストのFAILを確認してから、AES-GCMとKeychain、backup除外／file protection、bounded SQLiteアクセスを実装する。削除やKeychain失敗を成功と偽らず、再試行できる状態を表示する。
- [ ] 現行署名のapp/ext実機で共有Keychainを読む。AppleがApp Group名の共有を認めている根拠と実際の署名entitlementを照合する。既存token Keychainには移行を掛けない。profile/ipa_verifierの変更を先に増やさず、実際に必要になった差分だけをレビューする。
- [ ] `swift test --package-path Packages/InterceptorAutomation --filter AutomationStorageTests`と実機共有テストをPASSさせる。Commit候補: `feat(automation): persist authorized encrypted deliveries`。

## Task 6: Webhook送信

**Files:** Create `Sources/AutomationTransport/{EndpointPolicy,AddressResolver,NativeWebhookTransport,ResponseHeadParser,RetryPolicy}.swift`、`Tests/AutomationTransportTests/{EndpointPolicyTests,TransportTests,RetryPolicyTests}.swift`。
**Interfaces:** `send(request: AuthorizedWebhookRequest, credential: EndpointCredential, cancellation: CancellationToken) async throws -> DeliveryOutcome`。DeliveryOutcomeはstatus、retryAfter、理由コードのみ。任意のresponse bodyや認証値を返さない。

- [ ] URL userInfo/fragment、IP literal、private/link-local/予約IP、IPv4-mapped IPv6、DNS混在／rebinding、CRLF、invalid TLS、redirect、巨大response headerを拒否するfixtureを作る。
- [ ] `testPinsAddressAndValidatesOriginalTLSHostname`、`testNoProxyCookiesOrRedirect`、`testRetryUsesSameIdAndBytes`、`testClassifies2xx4xx4295xxAndTimeout`、`testRetryAfterCannotExtendTTL`を先にFAILさせる。
- [ ] `testNAT64PublicAddressAndPrivateEmbedding`、`testDeadIPv6FallsBackToIPv4WithinDeadline`、`testOnlyWinningConnectionPosts`を追加する。250 ms差・最大2接続で検証済み候補を試し、全体10秒を超えない。
- [ ] `testAsyncResolverDeadlineCancellationAndPathChange`、`testRateLimitCountsEveryAttemptOnceAndQueuesWithinTTL`を追加する。DNSは最大3秒・候補8件、初回/retry/429を1試行1枠で計数し、枠待ちjobもOutbox上限/TTLへ含める。
- [ ] G2で証明したNetwork.framework方式を実装する。public IP接続に元hostのSNI/SSL policyを付ける。nativeが生成するPOST JSON以外を送らず、HTTP1の最終response headだけを8 KiB以内で取得する。
- [ ] 408/429/5xx/一時障害だけを5/30/120/600秒±20%で再試行する。タイムアウト10秒、同時2、rate limit、認証エラーの表示、TLS/policyエラーの終了を固定する。
- [ ] `swift test --package-path Packages/InterceptorAutomation --filter AutomationTransportTests`をPASSさせる。試験は所有するlocal TLS fixtureとDIを使い、実製品のprivate-IP拒否をTESTフラグで恒久的に緩めない。Commit候補: `feat(automation): deliver authorized HTTPS webhooks`。

## Task 7: PacketTunnelと撤回・再起動の統合

**Files:** Create `PacketTunnel/AutomationWorker.swift`、`Interceptor/Automation/{AutomationController,RecordEventReader}.swift`、`InterceptorTests/{AutomationLifecycleTests,AutomationMigrationTests,RecordEventReaderTests}.swift`。Modify `PacketTunnelProvider.swift`、`Tuberose.swift`、必要なprovider messageの型。Mudmouthのv2定数変更はTask 2で完了させる。
**Interfaces:** `AutomationWorker.start(session:) async throws` / `stop(reason:) async` / `offer(_:) -> Bool`。provider messageはrevision通知、synthetic test、状態照会、撤回ackをversion付きJSONで扱い、上限16 KiB・未知version拒否。

- [ ] DIしたworkerで `testRestartRecoversOnlyAuthorizedUnexpiredJobs`、`testGlobalConsentWithdrawalStopsNewPermits`、`testTwoWorkersCannotClaimSameLease`を先に書く。実機の `testAppSuspensionDoesNotStopTunnelAutomation`、`testRequestWithoutResponseDelivers` は別E2E手順とし、SimulatorのPASSで代用しない。
- [ ] 撤回を送信許可の直前／直後へ差し込む制御可能なテストを作り、未許可の新規送信は0、既送信の取り消し不能は仕様どおりに扱う。
- [ ] sink受け渡しqueue32件と唯一のworkerをlifecycleに結ぶ。stop時にJS/接続をcancelし、leaseを回収、停止完了を待つ。無制限Taskを作らず、過負荷drop・TTL・失効を理由コードで可視化する。
- [ ] CaptureAuthorization v2と移行を実装する。v1から勝手に外部送信を有効化せず、再同意まではcapture自動開始を抑止する。Webhook未許諾でも再同意後の従来captureは使えるようにする。
- [ ] app起動時のv1検出でACTIVATE_ON_FOREGROUND=false、On Demandを無効にして既存接続を停止する。appが開かれる前のext起動もv2不一致でfail closedとする。再同意だけで自動再接続設定を戻さず、利用者に再設定を案内する。`testV1MigrationDisablesForegroundAndOnDemandRestart`で確認する。
- [ ] `RecordEventReader.readMetadata(id: UUID) async throws -> AutomationEvent`を専用ModelActorで実装する。propertiesToFetchでbodyを取得せず、明示fixtureはstream readで32 KiBまでにする。`testDryRunMetadataFetchDoesNotMaterializeHugeBody`と`testDryRunBoundedGzipFixture`を実測し、誤ってRecord.bodyを呼ぶ実装を検出する。
- [ ] `testRestartQuarantinesUnfinishedInvocationAndCaptureStillRuns`を追加し、JS開始前markerと再起動時の隔離、手動再開を検証する。
- [ ] `testGracefulStopClearsOwnInvocationMarker`を追加し、通常のcancel/stop後は隔離されないことを確認する。G1/A9でmarker I/Oのp95合計50 ms、invocation最大10回/秒、event全体5秒TTLを測定する。
- [ ] 同じhostがcaptureとendpointに設定されないことを全設定変更経路で検査する。dry-runは送信もOutbox追加も行わず、synthetic live testは唯一のworkerへ依頼する。
- [ ] `python3 scripts/automation-verify.py --mode simulator --device iphone --only-test InterceptorTests/AutomationLifecycleTests`はDIしたstate machine検証に限定する。実機E2EはTask 9で行い、既存の同意・VPN起動失敗・token抽出テストも通す。Commit候補: `feat(automation): integrate tunnel workers and revocation`。

## Task 8: 管理画面と利用者の確認導線

**Files:** Create `Views/Automation/{AutomationListView,PluginEditorView,PluginConsentView,EndpointEditorView,DeliveryHistoryView}.swift`、`InterceptorUITests/AutomationUITests.swift`。Modify `SettingsView.swift`、`DataUseConsentView.swift`、`Localizable.xcstrings`、既存editor部品。
**Consumes:** AutomationControllerのsnapshotと操作。実行器・DB・認証をViewへ直接持ち込まない。

- [ ] `testCreateImportEditEnableAndRemovePlugin`、`testDryRunNeverSends`、`testConsentShowsDestinationAndDataScope`、`testRevisionEditRequiresReapproval`、`testDisableCancelsPendingDelivery`をUI testとして先に追加する。
- [ ] 公開リポジトリの登録・配布スクリプト一覧・選択追加・更新確認を実装する。取得元／固定リビジョン／ソース／要求権限を表示し、取得失敗や不正な配布一覧を明示する。リポジトリの読み込み時には実行せず、既存プラグインを黙って上書きしない。`testRepositoryImportSelectsScriptWithoutExecuting`、`testRepositoryUpdateRequiresReview`で確認する。
- [ ] 一覧→作成／import→編集→dry-run→権限確認→有効化の流れを実装する。importは無効状態、上書きは差分確認。endpoint秘密値はマスクし、許諾先hostと送信例を明示する。
- [ ] Runestone/TreeSitterJavaScriptを再利用する。保存時に自動実行せず、構文エラーを行付きで表示する。payload previewの秘密をスクリーンショットfixtureへ混ぜない。
- [ ] en/ja × iPhone/iPad × Light/Dark、標準文字サイズ/VoiceOverで、長いURL・長いコード・エラー・空状態・送信中・停止状態を確認する。初回capture同意とoptional webhook許諾を混同しない。
- [ ] `python3 scripts/automation-verify.py --mode simulator --device ipad --appearance dark --only-test InterceptorUITests/AutomationUITests`等を実行し、画像とcleanup記録を残す。ネットワークはDI fixtureとし、実トンネルの証明にはしない。Commit候補: `feat(ui): manage plugins and webhook consent`。

## Task 9: 全要件の受け入れと公開準備

**Files:** Modify `.github/workflows/ios.yml`、必要なpackage pin/署名契約、`docs/app-review/{privacy-policy-draft,apple-policy-disclaimer,review-notes-draft}.md`、`fastlane/metadata/{en-US,ja}/`、`README.md`、`SETUP.md`。Create `docs/automation/acceptance-evidence.md`。別webリポジトリの公開Policyにも独立変更を用意する。

- [ ] 下記受け入れ表の全項目を実データのないfixture／所有する検証endpointで実施し、実行host、source SHA、OS、結果・ログ・画像の場所を記録する。
- [ ] `swift test --package-path Packages/InterceptorAutomation`、既存iOS全テスト、`ruby fastlane/test/run_all.rb`、変更SwiftのSwiftFormat/SwiftLintを実行する。既存lint失敗と新規失敗を区別し、新規失敗は解消する。
- [ ] iOS最低対応実機と現行OSのiPhone/iPadで、画面を閉じて30分、断線復旧、lock、トンネル再起動、queue満杯、JS攻撃入力を検証する。追加RSS/転送p95/トンネル停止の予算を測り、失敗を未実施や成功に読み替えない。
- [ ] 実際のコードdiffを独立Claude Code reviewerへ渡す。難しい全体レビューは、LocalGPT自身の対象ファイルアクセスを検証できる場合のみProにも依頼する。重大指摘を解消し、変えた箇所を再検証する。
- [ ] 現行の公開文書、consent v2、PrivacyInfo/ASC App Privacy、en/ja metadata、Review NotesとLICENSEを整合させる。過去buildの証跡は書き換えない。
- [ ] G0/G1/G2と全項目が成立したビルドだけを既存の正規PR→CI→TestFlight経路で配信する。実際のversion/build、source SHA、処理・配信状態を確認する。審査未確定時は本書の公開条件未達と記録し、機能を隠した出荷を「全機能完成」と扱わない。

Task 9の技術検証はA1〜A11とG1/G2、所有Simulatorのcleanupで記録する。A12/G0は別の公開判定であり、Appleが未回答・否定の場合は技術検証を完了として記録できるが、公開は未完了のまま残す。最後のMudmouth固定SHAとapp SHAが検証証跡／出荷物に一致しなければ、変更の影響範囲を再検証する。

## 受け入れ表

A1〜A11は実装・実機検証、A12は公開の条件。今回の計画書作成時点でこれらの実装成功を主張しない。

| ID | 合格の証拠 |
|---|---|
| A1 プラグイン | 公開リポジトリの登録・配布スクリプトの選択追加・更新差分確認と、作成・Files import・編集・削除を日英UIで操作。取得元／固定revisionを表示し、import後は無効状態。読み込み時の実行・Webhook送信・キャプチャ先追加・旧revisionの許諾引き継ぎは0。更新は確認後にのみ適用 |
| A2 JavaScript | 実JSがrequest/responseの条件とJSONを加工し、構文／実行例外とソース行が表示される。制限超過からVMを回収できる |
| A3 request Webhook | responseを返さないfixtureでrequest.completedを受信し、指定先へ1つのdeliveryIDで届く |
| A4 response Webhook | status/body条件を満たしたresponseだけが届く。1xx、chunked、HEAD、pipeliningで対応付けを誤らない |
| A5 background | appを閉じた実機でトンネル稼働中にA3/A4が成立。OS停止中の保証はしないことをUIで説明 |
| A6 grantと撤回 | 非許諾projectionに秘密が含まれず、別EndpointIDを拒否。取り消し後に新しい送信許可が出ない |
| A7 retryと回復 | 429/5xx/timeout/再起動で同じID・同じpayload、5試行/15分で打ち切り。初回/retryが1試行1rate枠、枠待ちもTTLへ含む。重複が起こり得ることを確認・説明 |
| A8 宛先制約 | DNS rebinding/IPv6/redirect/TLS異常/自己キャプチャを実経路で拒否。正常な外部HTTPS endpointは送れる |
| A9 障害分離 | VM異常、保存失敗、queue満杯、巨大／圧縮bodyの負荷でも転送p95追加5 ms以下、30分のトンネル停止0。marker I/Oのp95合計50 ms、正常stop後の誤隔離0、所有Simulator cleanup確認 |
| A10 UX | en/ja・両端末・両外観・標準文字サイズで権限、送信例、エラー、期限切れ、無効化を認識できる。dry-runの外部送信0 |
| A11 migration | v1から外部送信が自動ONにならず、capture同意v2後に従来機能・token抽出・通知が回帰しない |
| A12 公開 | G0・技術検証の成立と現行Policy/ASC/署名/ライセンスをレビューし、実配信と最終app/Mudmouth SHAを照合。Apple未確定／否定なら公開条件未達と記録 |

## 工数の目安と進め方

1人相当で合計30〜50作業日を初期目安とする。G1/G2でnative送信・runtime・保存の難度を測り、基盤、JS/配送、統合/UI、実機回帰の内訳を見積もり直す。審査回答・実機調達の待ち時間は含めない。pipeliningの正確さやUI検証を省いて見積もりを小さく見せない。

最初にTask 0/1を通し、その後ファイル所有を分けて進める方式を推奨する。実装開始前にはこの設計と計画の内容をレビューし、現在のAGENTS.mdに従って作業方法を確定する。

## 計画レビュー記録

以下は2026-10-15時点の設計に対する記録。2026-10-16追加のリポジトリ配布要件について、詳細設計・実装・実機動作まで検証済みとするものではない。配布方式の詳細レビューはTask 0で行う。

- Claude Code Sonnet 5.5: exact app SHAを独立調査。公開文言との矛盾、再同意、共有Keychainと署名、2つのhost定義、依存SHA連携、実行中断、Outbox失効を指摘。上記仕様・Task 0/2/4/5/7/9へ反映。
- ClaudeはMudmouth checkout未確認。Codexが固定版ソースを確認し、response-end保存とは別にrequestイベントが必要なこと、一括gzip getterを避けること、単一EventLoopであることを確認した。
- レビュー案の「requestをresponseと対にしてから通知」はA3を満たさないため採用しない。TreeSitterJavaScriptは新規導入ではなく、既存リンクを使う。
- LocalGPT GPT 6 Proの構成レビュー完了。LocalMCP接続不通のためファイルレビューではない。宛先別projection、JS内intrinsic/例外変換、累積CPU、NAT64、crash隔離を採用。永続inboxの追加提案は採用せず、観測〜Outbox確定前の欠落を明示する小さい契約を維持した。任意のWebhookへの永久送達は元の要件にない。
- 独立Claudeの実ファイルレビューで、Simulator/実機の区別、phase/manifest、型/target graph、dry-run、依存公開手順、rate limit、移行を具体化した。App Group KeychainはApple一次資料で確認し、新entitlement前提を撤回した。
- レビューの「@testable Mudmouthが使えない」という一般論は、既存InterceptorTests.swiftと実際に成功したDebug CIの利用実績に合わせ、testing設定の維持を条件として扱った。QuickJSの版とXcode 27はCodexが公式配布／実際のCI定義で確認した。
- 依頼された計画書の完成と、将来の実装・実機検証・Apple公開判断を分ける。全3機能を落とす縮小提案は採用しない。
- 最終の実ファイル再レビュー（2026-10-15、Claude Code Sonnet 5.5）は重大な未解決指摘なし。残った非重大な観察に対して、invocation枠を超えたeventは5秒TTL内で待機し期限切れを計数する、と1行明記した。これは計画文書のレビューであり、実装・試験・Apple承認の成功を意味しない。
