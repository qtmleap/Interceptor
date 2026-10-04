# Interceptor 修正計画書 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** レビューで確認した6件を修正し、依存解決とビルドを再現可能にし、取得データによるクラッシュとVPN接続状態の誤表示を防ぐ。

**Architecture:** 先に外部依存を復旧し、実際のMudmouthのAPIとデータ形式を確認する。その後、HTTPヘッダーとCookieの解析、AccessToken初期化、VPN操作と表示の同期を小さな変更として実装する。データモデルの保存形式と既存の取得対象は維持する。

**Tech Stack:** Swift、SwiftUI、Swift Package Manager、NetworkExtension、KeychainAccess、Mudmouth、XCTest、Xcode、fastlane。

**Spec:** 本書の「修正対象と調査根拠」。2026年10月4日のリポジトリレビューを元に作成。

## 修正対象と調査根拠

| 番号 | 優先度 | 問題 | 根拠と検証範囲 |
| --- | --- | --- | --- |
| 1 | P1 | QuantumLeapの固定SHAを取得できない | Package.resolvedのSHAは`d7e8cf36ade39306a8e1f3943c380352285db9ee`。レビュー時の0.0.7タグは`30dac2509deea3d935bb70fcc3f1730a24248641`。xcodebuildは固定SHAのチェックアウトに失敗した。 |
| 2 | P1 | Mudmouthがリポジトリ外にあり、取得手順がない | project.pbxprojは`../Mudmouth`を参照。このワークツリーと元のチェックアウトの隣にパッケージは存在しない。 |
| 3 | P1 | 同名Cookieでクラッシュ | Tuberose.swiftの解析コードを抽出し、`session=one; session=two`でDictionaryの重複キートラップを再現。 |
| 4 | P2 | ヘッダー名の大小文字で取得に失敗 | 抽出した実コードで、`host`と`x-gamewebtoken`が読み取れずnilになることを再現。 |
| 5 | P2 | 不正なGameWebTokenでクラッシュ | AccessToken.swiftの`try!`に外部入力が渡る。実ライブラリによる不正入力の再現は依存復旧後に行う。 |
| 6 | P2 | VPN開始失敗後もスイッチがON | VPNSetting.swiftに開始失敗時の表示復旧がない。実機の接続失敗とMudmouthの状態通知は未検証。 |

P1は高、P2は中の修正優先度。前回レビューではコンパイルとアプリ全体のテストまで到達していないため、依存復旧後の結果で計画を補正する。

## パッケージ同梱状況

**すべて同梱されている状態ではない。** 追跡されているのはアプリと拡張のソース、および依存設定・ロックファイルである。

| 依存 | 現在の指定 | パッケージ本体の同梱 |
| --- | --- | --- |
| Mudmouth | ローカルパッケージ`../Mudmouth` | 同梱なし。追加依頼により`https://github.com/qtmleap/Mudmouth`を兄弟ディレクトリにクローンした。取得SHAは`ddcefe656c0f27289ee4f506f2112b8bbdaa407d`。 |
| QuantumLeap | 非公開GitHubのリモートSwiftパッケージ | なし。固定SHAの取得失敗と、読み取り認証が必要。 |
| Firebase iOS SDK | GitHubのリモートSwiftパッケージ | なし。SPMによる取得が必要。 |
| Runestone | GitHubのリモートSwiftパッケージ | なし。SPMによる取得が必要。 |
| treesitterlanguages | GitHubのリモートSwiftパッケージ | なし。SPMによる取得が必要。 |
| KeychainAccess、SwiftyLogger、NIOなど | importまたはPackage.resolvedに記録 | ソースの同梱なし。直接・推移依存の関係はMudmouth復旧後に確定する。 |
| fastlaneとRuby依存 | GemfileとGemfile.lock | gem本体の同梱なし。bundle installによる取得が必要。 |

`Package.resolved`と`Gemfile.lock`は依存バージョンの記録であり、実装コードやバイナリではない。XcodeのSourcePackages等のキャッシュもリポジトリ同梱物には含まれない。

## Global Constraints

- 当初は計画書のみの依頼。追加依頼によりローカル開発環境のセットアップと必要な依存設定の修正まで進める。取得処理とVPN表示の修正、コミット・配布は未着手。
- 実装時も既存のトークン保存キーとCodableの保存形式を維持する。
- HTTPヘッダー名は大小文字を区別せず、Cookie名は大小文字を区別する。
- Mudmouthの取得元はユーザー指定の`https://github.com/qtmleap/Mudmouth`。クローン済みのソースを基準に互換性を確認する。
- QuantumLeap以外の依存は必要性が確認できない限り一括更新しない。
- アプリとPacketTunnelのDeployment Targetは現在の17.0を維持する。テストターゲットの18.5との相違は検証環境の選定時に扱う。
- 実トークン・個人情報はテストfixtureやドキュメントに保存しない。

## Review Focus

- 同名Cookieが複数ある入力：プロセスを終了させず、定めた選択規則を適用する。
- 小文字・混在ケースのHTTPヘッダー：HostとX-GameWebTokenを取得できる。
- Cookie値の`=`と空文字：値を壊さずに解析し、名前だけの不正な要素は除外する。
- 不正なJWTや未知のpayload：エラーとして扱い、既存の保存済みトークンを上書きしない。
- VPN開始失敗と外部状態変化：表示を実状態に合わせ、状態同期そのものではVPN操作を発火させない。

## Task 1 依存関係とビルドの復旧

**Files:**
- Modify: `Interceptor.xcodeproj/project.pbxproj`
- Modify: `Interceptor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Modify: `README.md`

**Interfaces:**
- Consumes: 現在のSPM設定、MudmouthをimportするアプリとPacketTunnel。
- Produces: クリーンチェックアウトから取得できるMudmouthとQuantumLeap、および実際のGameWebToken・VPN API。

- [x] ユーザー指定のMudmouthリポジトリを取得し、Package.swiftが公開するMudmouth製品と既存参照の一致を確認した。取得SHAは`ddcefe656c0f27289ee4f506f2112b8bbdaa407d`。
- [x] ユーザーのローカル開発希望に合わせて既存のローカルSPM参照を維持し、兄弟ディレクトリへの配置手順と取得SHAをREADMEに明記した。
- [x] QuantumLeapの0.0.7の取得可能なSHAを確認してロックファイルを修正し、SPMによる依存解決が終了コード0になることを確認した。アプリとの互換性はビルドで確認する。
- [x] 依存差分を確認し、無関係なLicenseListの自動更新を除外した。
- [x] READMEに依存取得、実際の対応iOS/Xcode条件、ビルドとテストの手順を記載した。
- [ ] 空のパッケージ取得先で次のコマンドを実行する。期待結果：依存解決が終了コード0となり、アプリとVPN拡張がBUILD SUCCEEDEDになる。

```bash
xcodebuild -resolvePackageDependencies -project Interceptor.xcodeproj -scheme Interceptor -clonedSourcePackagesDirPath /tmp/interceptor-review-packages
xcodebuild build -project Interceptor.xcodeproj -scheme Interceptor -destination 'generic/platform=iOS Simulator' -clonedSourcePackagesDirPath /tmp/interceptor-review-packages CODE_SIGNING_ALLOWED=NO
xcodebuild -showdestinations -project Interceptor.xcodeproj -scheme Interceptor
```

- [ ] 利用可能なiOS 18.5以降のSimulator IDを選び、以後のテストに同じIDを使用する。実機VPNテストは別途行う。
- [ ] この単位をレビューし、`fix: restore reproducible package resolution`としてコミットする。

## Task 2 HTTPヘッダーとCookie解析の修正

**Files:**
- Modify: `Interceptor/Classes/Tuberose.swift`
- Test: `InterceptorTests/InterceptorTests.swift`

**Interfaces:**
- Consumes: 通知からデコードされた`[String: String]`。
- Produces: `headerValue(forKey: String) -> String?`、既存の`host: String?`と`cookies: [String: String]?`。
- Cookie重複の規則：最初の出現を保持する。これは本アプリの明示的な選択であり、HTTP仕様が順序による優先を保証するという意味ではない。

- [ ] 以下の失敗テストを追加する。`testDuplicateCookieKeepsFirstValue`はCookie `session=one; session=two`の結果が`session: one`になることを確認する。`testHeaderNamesAreCaseInsensitive`は`host`と`x-gamewebtoken`で値が取得できることを確認する。
- [ ] `testCookieValuesPreserveEqualsAndEmptyStrings`で`a=x=y; b=; invalid`が`a: x=y`、`b: 空文字`となり、invalidが含まれないことを確認する。`testCookieNamesRemainCaseSensitive`で`A=one; a=two`が別キーになることを確認する。
- [ ] 現行実装でテストが失敗することを確認する。重複Cookieのテストはプロセス終了するため単独実行する。
- [ ] ヘッダー専用の大小文字を区別しない検索を実装し、hostとX-GameWebTokenの取得に使用する。Cookieの値検索は既存の完全一致を維持する。
- [ ] Cookie解析を重複キートラップのない逐次格納に変更し、`=`は最初の1つでのみ分割する。空の値と欠落した区切り文字を区別する。
- [ ] Mudmouthが通知ヘッダーを正規化するか確認し、実際の通知形式でも解析できることを確認する。
- [ ] 対象テストを実行して終了コード0を確認し、`fix: handle cookie duplicates and header casing`としてコミットする。

## Task 3 トークン初期化の安全化

**Files:**
- Modify: `Interceptor/Structs/AccessToken.swift`
- Modify: `Interceptor/Classes/Tuberose.swift`
- Modify: `../Mudmouth/Sources/Mudmouth/Structs/GameWebToken.swift`（別リポジトリ）
- Test: `InterceptorTests/InterceptorTests.swift`

**Interfaces:**
- Consumes: Task 1で復旧したGameWebTokenのthrowing initializer。
- Produces: `AccessToken.init(contentId: ContentId, host: String, gtoken: String, accessToken: String, timeInterval: TimeInterval = 60 * 60 * 2) throws`。
- Mudmouthの`GameWebToken.init(_ value: String) throws`は公開シグネチャを維持し、内部の不正入力もthrowとして返す。

- [ ] MudmouthのGameWebTokenデコーダーを読み、必要なpayload項目を満たす合成fixtureを作る。実際の認証情報は使わない。
- [ ] `testMalformedGameWebTokenThrows`で`gtoken: not-a-jwt`がエラーになることを確認する。`testUnsupportedGameWebTokenPayloadThrows`で必要項目を欠くpayloadがエラーになることを確認する。`testValidGameWebTokenPreservesStoredFields`で合成fixtureの正常系とCodable往復を確認する。
- [ ] throwing initializerがまだない状態で、テストが失敗することを確認する。
- [ ] クローン後の追加確認：MudmouthのGameWebTokenにもJSONデコードの`try!`と未検証の`data[0]`・`data[1]`がある。JWTの要素数・各要素のBase64URLデコードを検証し、JSONデコードを`try`で伝播する。不正なBase64URL、3要素を超える入力、header/payload欠落でもクラッシュしないことを回帰テストに追加する。アプリ側だけの修正では完了としない。
- [ ] `try!`を除去し、呼び出し元の3つの取得分岐でAccessToken生成を成功させてからKeychainへ書き込む。失敗時は既存値を保持する。
- [ ] 不正なトークンを含む通知を処理し、アプリが終了せず、以前の保存値が維持されることを確認する。Keychainを使う検証は専用テストサービスで行い、終了時に片付ける。
- [ ] 正常系・異常系テストを実行して終了コード0を確認し、`fix: reject malformed captured tokens safely`としてコミットする。

## Task 4 VPN操作と表示状態の同期

**Files:**
- Create: `Interceptor/Classes/VPNConnectionState.swift`
- Modify: `Interceptor/Components/VPNSetting.swift`
- Modify: `Interceptor/Classes/Tuberose.swift`
- Test: `InterceptorTests/InterceptorTests.swift`

**Interfaces:**
- `@MainActor protocol VPNConnectionControlling`：`var isConnected: Bool { get }`、`func startVPNTunnel() async throws`、`func stopVPNTunnel()`。Tuberoseを準拠させる。
- `@MainActor final class VPNConnectionState: ObservableObject`：`@Published private(set) var isConnected: Bool`、`@Published private(set) var errorMessage: String?`、`func setConnected(_ requested: Bool, using client: any VPNConnectionControlling) async`、`func synchronize(with client: any VPNConnectionControlling)`、`func clearError()`。
- `synchronize`は表示のみ更新し、start/stopを呼ばない。開始成功直後も実状態を読み、Mudmouthの確定通知に追従する。

- [ ] 開始失敗・正常開始・停止を制御できるFakeVPNClientをテスト内に作る。
- [ ] `testStartFailureRestoresDisconnectedState`で開始がthrowすると表示falseかつエラーありを確認する。`testSuccessfulStartReflectsActualStatus`で正常開始時の状態を確認する。
- [ ] `testStatusSynchronizationDoesNotIssueVPNCommands`で外部状態の同期時に開始・停止の呼び出し回数が増えないことを確認する。
- [ ] `testStopReflectsAsynchronousStatusChange`で停止直後は実状態を表示し、後続の同期でfalseになることを確認する。
- [ ] 新しい状態クラスがない状態でテストが失敗することを確認し、上記インターフェースを実装する。
- [ ] VPNSettingのスイッチのユーザー操作からのみsetConnectedを呼ぶ。onAppear・状態通知ではsynchronizeを使用する。開始失敗はalertで表示する。
- [ ] Mudmouthの状態変更の観測方法を実装に合わせて確認する。既存のonChangeが通知を観測できない場合は、実ライブラリが提供するVPN状態通知に接続する。
- [ ] テストを実行して終了コード0を確認し、`fix: synchronize VPN switch after connection failure`としてコミットする。

## Task 5 全体検証

- [ ] Task 1で選んだSimulator IDで単体テストと既存UIテストを実行する。下記のSIMULATOR_IDは実際のUUIDに置換する。

```bash
xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=iOS Simulator,id=SIMULATOR_ID' -only-testing:InterceptorTests
xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=iOS Simulator,id=SIMULATOR_ID' -only-testing:InterceptorUITests
xcodebuild build -project Interceptor.xcodeproj -scheme Interceptor -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] 実機でVPN開始・停止・開始拒否と前面復帰を確認する。Simulatorの結果だけでNetworkExtensionの実通信が動作したと判断しない。
- [ ] 実機でSplatoon 2、Splatoon 3、Smash Worldの取得から保存、画面表示まで確認する。記録にトークン値は含めない。
- [ ] クリーンチェックアウトでREADMEの手順を実行し、個人の依存キャッシュや未記載の兄弟リポジトリに頼らないことを確認する。
- [ ] 変更全体をレビューし、コマンド結果と未検証項目を修正報告に記録する。

## 完了条件

- 依存解決が成功し、アプリとPacketTunnelをDebug・Releaseでビルドできる。
- 重複Cookieと不正トークンでクラッシュせず、ヘッダーの大小文字で取得結果が変わらない。
- 保存形式を維持し、失敗した取得では既存のトークンを失わない。
- VPN開始失敗後の表示が実状態に戻り、表示同期で余分な開始・停止を発火しない。
- 回帰テストが成功し、実機での検証結果または残った制約を明記する。

## 計画の確認記録

6件すべてをTask 1〜4に割り当てた。解析の重複・大小文字・値の境界はTask 2、トークンの正常系と異常系はTask 3、VPN操作と状態同期はTask 4で検証する。追加依頼によりTask 1のセットアップを開始した。Mudmouthの取得元は確定済みで、実機検証は未実施。クローン後に見つかったMudmouth内部のJWT解析の問題はTask 3へ追加した。

セットアップ時、QuantumLeap 0.0.7の旧SHAがMacのSPM fingerprint記録にも残っていた。該当ファイルを`/tmp/interceptor-quantumleap-fingerprint-before.json`へバックアップし、そのバージョンの旧記録だけを除去して再取得した。XcodeのKeychain認証待ちを避けるため、公開パッケージの取得に`-packageAuthorizationProvider netrc`を使用した。

検証用に通常と異なるパッケージ保存先を指定するとLicenseListプラグインが`SourcePackages not found`で停止した。カスタム保存先を使う検証では、同プラグインの`PLL_SOURCE_PACKAGES_PATH`環境変数にも同じパスを指定する。READMEの標準保存先を使う手順ではこの指定は不要。

## ローカルビルド確認結果

2026年10月4日、依存更新前にはXcode 26.0.1（17A400）で下記のビルドを実行し、終了コード0と`BUILD SUCCEEDED`を確認した。Interceptor.appとPacketTunnel.appexを生成し、Simulatorのarm64とx86_64を対象にビルドした。実機の署名・VPN通信、Releaseビルド、テストは今回の確認対象外。

```bash
DEVELOPER_DIR=/Applications/Xcode-26.0.1.app/Contents/Developer PLL_SOURCE_PACKAGES_PATH=/tmp/interceptor-local-packages xcodebuild build -project Interceptor.xcodeproj -scheme Interceptor -destination 'generic/platform=iOS Simulator' -clonedSourcePackagesDirPath /tmp/interceptor-local-packages -derivedDataPath /tmp/interceptor-local-build-xcode26 -packageAuthorizationProvider netrc -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO
```

ログ：`/tmp/interceptor-local-build-xcode26.log`。

依存更新前のXcode 27.0（27A266a）では、swift-cryptoの_CryptoExtras内の`@TaskLocal`展開に`unknown attribute 'usableFromInlinenonisolated'`が発生し、終了コード65で失敗した。ログ：`/tmp/interceptor-local-build.log`。追加依頼により下記の依存更新で対応し、現在はXcode 27.0でもビルドできる。

## Xcode 27向けの依存更新結果

| 依存 | 更新前 | 更新後 | 更新理由 |
| --- | --- | --- | --- |
| swift-crypto | 3.14.0 | 3.15.1 | エラーが発生したTaskLocalを使用する実装が更新済み。swift-certificates 1.12.0の依存条件内で解決できる。 |
| Runestone | 0.5.1 | 0.5.2 | 新SDKでUIFindInteractionDelegateのavailabilityに関するコンパイルエラーが発生。0.5.2の修正を適用。 |

参考：[swift-crypto 3.15.1のソース](https://github.com/apple/swift-crypto/blob/3.15.1/Sources/_CryptoExtras/ECToolbox/BoringSSL/ECToolbox_boring.swift)、[Runestone 0.5.2のリリース](https://github.com/simonbs/Runestone/releases/tag/0.5.2)。

Package.resolvedの上記2つの固定バージョンとSHAを更新した。アプリ、Mudmouth、取得済み外部ライブラリのソースに独自パッチは当てていない。公開されたバージョンをSPMで取得し、既存の依存条件内で解決した。

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer PLL_SOURCE_PACKAGES_PATH=/tmp/interceptor-local-packages xcodebuild build -project Interceptor.xcodeproj -scheme Interceptor -destination 'generic/platform=iOS Simulator' -clonedSourcePackagesDirPath /tmp/interceptor-local-packages -derivedDataPath /tmp/interceptor-local-build -packageAuthorizationProvider netrc -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO
```

終了コード0、`BUILD SUCCEEDED`。Interceptor.appと内包するPacketTunnel.appexのarm64・x86_64 Simulatorビルドを確認した。ログ：`/tmp/interceptor-local-build-updated.log`。更新後の依存での実機動作、Release、テスト、およびXcode 26での再ビルドは未検証。

## Simulator動作確認結果

2026年10月4日、iPhone 17 Pro・iOS 26.5の専用Simulator「Interceptor Review iPhone」で動作を確認した。UUIDは`87D028AC-FFB0-4062-8725-EA9CD7A915E2`。

署名を無効にしたコンパイル確認用ビルドでは、App Groupの保存先を取得できず起動時にクラッシュした。アプリのソースを変更せず、Simulator用に`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`を指定して再ビルド・インストールすると正常に起動した。READMEにコンパイル確認と実行用ビルドの違いを追記した。

`InterceptorUITests/InterceptorUITests.swift`に`testSimulatorOnboardingAndNavigation`を追加した。SwiftUIのラベル付きスイッチは行全体がアクセシビリティの対象になるため、末尾のスイッチ位置をタップし、値の更新をpredicateで待つ。iOS 26の履歴削除確認はCancelボタンを前提とせず、専用の空履歴環境でClear操作を検証する。

| 検証項目 | 結果 |
| --- | --- |
| 初回案内の9画面をNextとDoneで進める | 初回実行で確認済み |
| ホームと設定のタブ切り替え | 成功 |
| Auto Connectを切り替え、元に戻す | 成功 |
| プロキシ対象リストとNintendoの対象ホスト表示 | 成功 |
| トークン一覧の表示と戻る操作 | 成功（トークン未取得の状態） |
| 証明書画面の表示と戻る操作 | 成功 |
| 空の履歴をClearし、画面を維持する | 成功 |
| アプリ再起動と初回案内の完了状態維持 | 成功 |

追加したUIテスト1件は終了コード0、`TEST SUCCEEDED`。最終実行時間は42.353秒。結果バンドルは`/tmp/interceptor-simulator-smoke-final.xcresult`、ログは`/tmp/interceptor-simulator-smoke-final.log`。初回案内は最初の実行で完了しており、最終再実行では完了状態から検証した。

追加の全テスト実行は終了コード0、`TEST SUCCEEDED`。6種類のテストを計9回実行し、失敗・スキップは0件。結果バンドルは`/tmp/interceptor-full-validation.xcresult`、ログは`/tmp/interceptor-full-validation.log`。既存の起動テストにはメインスレッド呼び出しに関する実行時警告があるが、テストの失敗はない。

その後、専用Simulatorからアプリをアンインストールして新規インストール状態で追加UIテストを再実行し、初回案内を含めて終了コード0、`TEST SUCCEEDED`を確認した（49.553秒、1件、失敗0件）。結果は`/tmp/interceptor-fresh-onboarding.xcresult`、ログは`/tmp/interceptor-fresh-onboarding.log`。

実際のVPN接続、通信記録の取得、実Nintendoトークン、トークン詳細の表示、iPad、実機署名、Releaseの実行は未検証。修正計画のTask 2〜4にあるアプリ本体の修正は未着手。

## CI追加とマージ前レビュー

GitHub Actionsの既存ワークフローはなかったため、`.github/workflows/ios.yml`を追加した。masterへのPRとpushで、Xcode 27ランナーを使ってSimulatorのコンパイルと全テストを実行する。Mudmouthはローカル確認と同じSHAに固定し、専用Simulatorを作成する。ビルドログとxcresultは7日間保存する。

独立レビューで、ローカルXcodeのプラグイン承認省略設定にCIが依存してしまう点を確認した。CIの両コマンドに`-skipPackagePluginValidation`を指定し、READMEにも初回のプラグイン承認手順を追記した。修正後の独立レビューにはマージを妨げる指摘は残っていない。ホストされたCIの成功を確認してからmasterへ反映する。

ホストされたCIではQuantumLeapの認証不足で依存取得が失敗した（run 37165605990）。QuantumLeapは非公開で、InterceptorのGITHUB_TOKENでは取得できない。CI専用の読み取りDeploy Keyの登録も、QuantumLeap側のポリシーによりHTTP 422で禁止されていた。個人アカウントの広い権限のトークンを転用せず、QuantumLeapだけのContents読み取り権限を持つ`QUANTUMLEAP_READ_TOKEN`をRepository Secretとして設定する構成にした。Secret設定後にCIを再実行し、成功後にmasterへマージする。

その後ユーザーから`gh auth token`を使用する明示指示があり、2026年10月4日に現在のgh認証トークンを`QUANTUMLEAP_READ_TOKEN`として登録した。値はパイプで直接渡し、ログ・チャット・リポジトリには保存していない。これは専用の読み取り権限に限定したトークンではないため、READMEでは専用トークンを推奨しつつ、必要条件をQuantumLeapへの読み取りアクセスと記載した。
