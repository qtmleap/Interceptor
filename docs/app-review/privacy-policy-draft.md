# Interceptor Privacy Policy — draft / プライバシーポリシー案

Source draft prepared 2026-10-04. An adapted bilingual policy was published on qleap.jp on 2026-10-04; use the public page as the authoritative published text. This source describes the revised release, not rejected build 28.

Draft updated 2026-10-06 for the proposed mandatory startup consent flow. This update has not been submitted to Apple or published to the public policy page. Uploaded build 30 retains the previous consent flow; verify the replacement build before using this draft.

Developer: Interceptor developer (qtmleap). The App Store legal developer entity has not been reconciled with the website business information.
Privacy contact: https://qleap.jp/support (existing public support path).
Published public policy URL: https://qleap.jp/term/interceptor_privacy_policy.
Published effective date: 2026-10-04.

## English

### What Interceptor does

Interceptor inspects selected Nintendo-related HTTPS traffic on your own device through a local proxy using an iOS VPN configuration. It does not provide a remote VPN server or a public Wi-Fi protection service. To inspect HTTPS, you must install and trust a certificate authority certificate generated locally by the app.

### Data accessed and purpose

After you explicitly consent to capture, the app can process and save request and response hosts, paths and query parameters, headers, cookies, authentication tokens, account identifiers, and bodies for its configured hosts, including paths beyond the endpoints used for token notifications. Some fields contain sensitive account or session information. The app uses these records to show you your traffic and to display supported service tokens. It also stores settings, consent state, and locally generated certificate/key material needed for inspection. Use the app only for devices, accounts, and traffic you are authorized to inspect.

### Storage and transmission

New capture records are stored in local shared storage used by the app and its packet-tunnel extension. Newly saved tokens, certificates, and private keys use Keychain items with iCloud Keychain synchronization disabled. Interceptor does not upload captured data to a developer-operated server, sell it, use it for advertising, or automatically share it with third parties. The revised release has no Firebase or Firebase remote messaging integration and does not request advertising tracking permission.

This does not mean that every network request remains on the device. The inspected requests still reach their intended Nintendo services, which process them under their own policies. Opening external support or policy links also connects to the selected website. If you copy data or share it outside Interceptor, the destination and its handling are your choice. Clipboard contents and subsequent sharing can expose sensitive information.

Earlier app versions may have saved synchronizable Keychain data. Disabling new synchronization does not erase earlier iCloud copies or copies on other devices. Apple's Keychain, device migration, and backup/restore behavior also depend on your system settings and the stored item's protection attributes. This policy does not promise that all data is excluded from OS backups or that uninstalling the app erases every Keychain item. Control existing cloud copies and backups through the relevant Apple services and device settings.

### Consent and controls

At startup, if you have not agreed to the current version of the data-use notice, the app presents a full-screen consent view that cannot be dismissed to access the main interface. Agreeing dismisses this view; without agreement, the main interface remains unavailable. Agreement does not start capture, install or trust a certificate, install a VPN configuration, or request notification permission. These remain separate user actions. You may read the notice and withdraw consent in Settings → Privacy. Withdrawal stops the VPN, disables automatic reconnection and clears capture notifications, and returns the app to the required consent view until you agree again. Withdrawal does not delete saved records, saved tokens, older cloud copies, certificates, or private keys, and does not remove installed certificate profiles.

Use Home's Clear action to delete the app's saved request history. This action does not claim to delete separately stored Keychain tokens or certificates. Data can remain until you delete it through an applicable control, and prior backups or manually copied data may remain separately. To end the certificate's trust and remove its installed profile, use iOS Settings; remove the VPN configuration there when no longer needed. Revoking or rotating a Nintendo session/token requires Nintendo's account or service controls.

Notifications are optional and generated locally. Their text and payload do not contain captured cookies, authentication tokens, headers, or bodies. The app reads captured results from its local storage. You can disable notifications in iOS Settings without enabling remote push or sending capture results to a push server.

### Questions and updates

Contact the verified privacy contact listed above with questions. A future change to capture scope, storage, or external sharing requires an updated explanation and policy. This draft does not establish that Apple has approved the app or its network inspection design.

## 日本語

### アプリの仕組み

Interceptorは、iOSのVPN設定と端末内のプロキシを使い、自分の端末で任天堂関連の一部のHTTPS通信を解析します。外部のVPNサーバーや公共Wi-Fiを保護するサービスは提供しません。HTTPS通信の解析には、アプリが端末内で生成した認証局証明書をインストールし、信頼する操作が必要です。

### 取得するデータと用途

通信の取得に明示的に同意した後、設定したホストへの通信（トークン通知の対象エンドポイント以外のパスも含む）について、リクエストとレスポンスのホスト、パス、クエリ、ヘッダー、Cookie、認証トークン、アカウント識別子、本文を処理・保存することがあります。アカウントやセッションに関する機密情報が含まれる場合があります。これらは、通信内容と対応サービスのトークンを利用者に表示するために使用します。設定、同意の状態、解析に必要な端末内の証明書と鍵も保存します。解析する権限を持つ端末、アカウント、通信だけを対象にしてください。

### 保存先と送信

新たな通信記録は、アプリとパケットトンネル拡張が使用する端末内の共有領域に保存します。新たに保存するトークン、証明書、秘密鍵には、iCloudキーチェーン同期を無効にしたKeychain項目を使用します。取得データを開発者のサーバーへアップロードしたり、販売したり、広告に利用したり、第三者へ自動共有したりしません。修正版ではFirebaseとFirebaseのリモート通知機能を使用せず、広告追跡の許可を求めません。

すべての通信が端末内で完結するという意味ではありません。解析対象の通信は、本来の送信先である任天堂のサービスへ送られ、そのサービスの方針に従って処理されます。サポートやポリシーの外部リンクを開いた場合は、リンク先のウェブサイトへ接続します。利用者がデータをコピーしてアプリ外で使用・共有する場合、その送信先と取り扱いは利用者が選ぶものです。クリップボードやその後の共有により、機密情報が外部へ渡ることがあります。

旧版では、同期可能なKeychain項目を保存していた可能性があります。新たな同期を停止しても、以前のiCloud上のコピーや他の端末のコピーは削除されません。AppleのKeychain、端末移行、バックアップと復元の扱いは、システム設定や保存項目の保護属性にも左右されます。すべてのデータがOSのバックアップ対象外になることや、アンインストールですべてのKeychain項目が消えることを保証するものではありません。既存のクラウド上のコピーとバックアップは、Appleの該当サービスや端末の設定で管理してください。

### 同意と操作

起動時に現在のバージョンのデータ利用説明への同意がない場合、閉じてメイン画面へ進むことのできない全画面の同意画面を表示します。「同意する」を選ぶとこの画面が閉じます。同意するまではメイン画面を利用できません。同意しただけで通信の取得、証明書のインストールや信頼、VPN設定のインストール、通知の許可要求は行いません。これらは、それぞれ別の利用者の操作で行います。設定の「プライバシー」から説明を再確認し、同意を撤回できます。撤回するとVPNを停止し、自動再接続を無効にし、取得通知を消去して、再び同意するまで必須の同意画面を表示します。撤回だけでは、保存済みの通信記録、トークン、過去のクラウド上のコピー、証明書、秘密鍵や、インストールした証明書プロファイルは削除されません。

通信履歴はホームの消去操作で削除できます。この操作で、別に保存されたKeychainのトークンや証明書も削除されるとは限りません。該当する削除操作を行うまでデータが残ることがあり、過去のバックアップや自分でコピーしたデータは別に残る場合があります。証明書の信頼を停止してプロファイルを削除する場合や、VPN設定が不要になった場合は、iOSの設定から操作してください。任天堂のセッションやトークンを無効化・更新する場合は、任天堂のアカウントやサービスの操作が必要です。

通知は任意で、端末内で生成します。通知の文面とペイロードには、取得したCookie、認証トークン、ヘッダー、本文を含めません。アプリは端末内に保存された取得結果を読み取ります。iOSの設定から通知を無効にできます。通知のためにリモートプッシュを有効にしたり、取得結果をプッシュ通知のサーバーへ送ったりしません。

### 問い合わせと更新

質問は、上記の確認済みの問い合わせ先へご連絡ください。取得対象、保存先、外部共有の方針を変更する場合は、説明とポリシーを更新します。この案は、Appleがアプリや通信解析の仕組みを承認したことを示すものではありません。
