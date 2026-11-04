import {page,row,section,badge,choice,notice,historyItem,toggle} from './components';
import {localizedProposalComponents} from './localized-proposal-components';
const base = `${import.meta.dir}/..`;
async function buildProposalScreens(lang: 'ja' | 'en') {
const {page,row,section,badge,choice,notice,historyItem,toggle,note} = localizedProposalComponents(lang);
const write = (name: string, html: string) => Bun.write(`${base}/mocks/${name}${lang === 'en' ? '-en' : ''}.html`, html);
const contents = `<p class="catalog-note">${note}</p>`
 +section('行',row('実行モード','通知して確認',true)+row('送信先','Example endpoint',true)+row('対象ホスト','api.example.com')+row('API','GET /api/account'))
 +section('状態',`<div class="row">${badge('ok','OK · 送信しました')}</div><div class="row">${badge('warn','WARN · 結果を確認できません')}</div><div class="row">${badge('error','ERROR · 認証に失敗しました')}</div><div class="row">${badge('neutral','実行の確認待ち')}</div>`)
 +section('実行モード',choice('オフ',true)+choice('通知して確認')+choice('全自動'),'通信に反応しません')
 +section('実行モード',choice('オフ')+choice('通知して確認',true)+choice('全自動'),'一致した通信を通知し、確認後に実行します')
 +section('実行モード',choice('オフ')+choice('通知して確認')+choice('全自動',true),'通知や確認なしでプラグインを実行し、履歴に記録します')
 +section('権限の要約',row('引き継ぐヘッダー','元のリクエスト')+row('外部へ送る項目','data'),['認証情報を含むヘッダーを、同じオリジンへの通信に使用します。','送信先は設定したエンドポイントに限定します。'])
 +section('案内・空・読み込み',notice('neutral','実行の確認待ちはありません'),'対象の通信が見つかると、ここに表示されます。')
 +section('',notice('neutral','読み込み中'),'実行状況を確認しています。')
 +section('',notice('warn','VPNが停止しています'),'接続すると、保留中の処理を実行できます。')
 +section('実行できない状態',notice('warn','確認の期限が切れました'),'新しく取得した通信から確認してください。')
 +section('',notice('warn','権限が変更されました'),'この処理は実行されません。設定から権限を確認してください。')
 +section('',notice('warn','結果を確認できません'),'APIがすでに処理した可能性があります。自動では再実行しません。')
 +section('',notice('error','認証に失敗しました'),'追加のAPI呼び出しが401を返しました。元のサービスでログイン状態を確認してください。')
 +section('履歴の行',historyItem('ok','送信しました','9:41','Account result · Example endpoint')+historyItem('error','APIに接続できません','9:38','Account result'))
 +section('',toggle('ヘッダーの読み取りを許可')+toggle('許可した状態',true)+toggle('変更できない状態',false,true))
 +section('追加の権限',toggle('元のヘッダーを外部に送る'),'有効にすると、宣言された送信先へ元のヘッダーを送信できます。外部送信を宣言したプラグインだけに表示します。');
await write('components',page('共通コンポーネント',contents,{back:'戻る',action:'実行',disabled:true}));

// Screen compositions use only the catalog's shared source definitions above.
const configuration = section('検出する通信',row('対象ホスト','api.example.com')+row('パス','/api/session')+row('メソッド','GET'),'ホスト、パス、メソッドはプラグインが定めた条件で、変更できません。')
 +section('実行モード',choice('オフ')+choice('通知して確認',true)+choice('全自動'),'オフ：反応しません。通知して確認：通知と確認待ち項目を作成し、実行を選ぶと開始します。全自動：通知や確認なしで実行し、履歴に記録します。')
 +section('',toggle('ヘッダーの読み取りを許可'),'このプラグインでは、元のリクエストのAuthorizationとCookieの値だけをスクリプトが読み取れるようになります。ログイン情報が外部サーバーに送られる可能性があるため、信頼できないスクリプトでは有効にしないでください。')
 +section('',row('実行の確認待ち','1件',true)+row('実行履歴','',true));
await write('configuration',page('実行設定',configuration,{back:'戻る',action:'保存'}));

const pending = section('',notice('neutral','実行の確認待ち'),'検出した通信に一致しました。実行を選ぶまで、追加のAPI呼び出しは行いません。')
 +section('検出した通信',row('対象ホスト','api.example.com')+row('パス','/api/session')+row('メソッド','GET')+row('検出した時刻','9:41'))
 +section('Account lookup',row('実行を選べる期限','あと14分'),'期限を過ぎると、この項目からは実行できません。新しく検出した通信から確認してください。ログインやスクリプトの有効期限ではありません。')
 +section('実行時に追加で行う通信',row('メソッド','GET')+row('API接続先','https://api.example.com')+row('APIパス','/api/account')+row('送信するヘッダー','元の通信のヘッダー')+row('応答情報','HTTPステータス・本文')+row('結果の外部転送','しない'),['検出した通信とは別に、同じホストのAPIをHTTPSで呼び出します。元のリクエストのログイン情報（AuthorizationやCookie）も、この接続先に送信されます。','この例は結果をローカルで処理し、別のサービスへは送信しません。']);
await write('pending',page('実行を確認',pending,{back:'戻る',action:'実行'}));

const history = section('実行の確認待ち · 1件',historyItem('neutral','Account lookup','検出 9:41','api.example.com · あと14分'),'ホスト名は検出した通信のものです。項目を開くと、実行内容と送信する情報を確認できます。開いただけでは実行されません。')
 +section('今日',historyItem('ok','完了しました','9:35','Account lookup')+historyItem('error','APIの認証に失敗しました','9:28','Account lookup · HTTP 401')+historyItem('warn','APIの結果を確認できません','9:20','Account lookup')+historyItem('neutral','確認の期限が切れました','9:01','Account lookup'),['結果不明：APIが処理済みの可能性があります。自動再実行はしません。繰り返す前にAPI側の状態を確認してください。','確認期限切れ：この実行を承認できる期限を過ぎました。ログインの有効期限ではありません。\nAPI認証失敗：追加APIが認証エラーを返しました。'])
 +section('通知の状態',notice('warn','通知はオフです'),'iOSの設定でInterceptorの通知を許可してください。通知なしでも、確認待ちはこの画面から開けます。');
await write('history',page('実行状況',history,{back:'戻る'}));

const grant = section('プラグイン',row('名前','Account lookup')+row('バージョン','1.0.0')+row('許可の範囲','このバージョンのみ'),'これは個別の実行の承認ではなく、このバージョンのアクセス権限です。許可してもAPIはすぐには呼び出されません。')
 +section('検出する通信',row('対象ホスト','api.example.com')+row('パス','/api/session')+row('メソッド','GET'))
 +section('許可する追加のAPIアクセス',row('メソッド','GET')+row('API接続先','https://api.example.com')+row('APIパス','/api/account')+row('送信するヘッダー','元の通信のヘッダー')+row('応答情報','HTTPステータス・本文')+row('結果の外部転送','しない'),['検出した通信とは別に、同じホストのAPIをHTTPSで呼び出します。元のリクエストのログイン情報（AuthorizationやCookie）も、この接続先に送信されます。スクリプトがヘッダーを読み取る権限とは別です。','結果は別のサービスへ転送されません。アクセス内容やバージョンの変更で、この権限は無効になります。実行設定の「実行モード」をオフにすると、このプラグインのアクセスは取り消されます。']);
await write('grant',page('アクセス権限',grant,{back:'戻る',action:'許可'}));
}
await buildProposalScreens('ja');
await buildProposalScreens('en');

// Adopted Dangerous composition, revised through independent UI-only review.
const dangerousCopy = {
  "WD_EXTERNAL_TITLE": [
    "ヘッダーの外部送信",
    "Header forwarding"
  ],
  "WD_SCRIPT_TITLE": [
    "ヘッダーの読み取り",
    "Header reading"
  ],
  "WD_EXTERNAL_RISK": [
    "ヘッダーに含まれるログイン情報や個人情報を、元のサービスとは別の送信先へ渡せるようになります。信頼できないプラグインでは有効にしないでください。",
    "This lets login details or personal data in headers be shared outside the original service. Do not enable it for plugins you do not trust."
  ],
  "WD_SCRIPT_RISK": [
    "このプラグインのJavaScriptが、下に挙げたヘッダーの値を読み取れるようになります。ログイン情報が含まれることがあるため、信頼できないプラグインでは有効にしないでください。",
    "This plugin’s JavaScript will be able to read the header values listed below. They may contain login details. Do not enable it for plugins you do not trust."
  ],
  "WD_EXTERNAL_HEADERS": [
    "送信を許可する元のヘッダー",
    "Original headers to forward"
  ],
  "WD_SCRIPT_HEADERS": [
    "読み取りを許可するヘッダー",
    "Headers JavaScript may read"
  ],
  "WD_EXTERNAL_PRIVACY": [
    "画面にはヘッダー名だけを表示しています。対応する元の値を、上の送信先へ送ることを許可します。",
    "Only names are shown here. This permits the corresponding original values to be sent to the destination above."
  ],
  "WD_SCRIPT_PRIVACY": [
    "画面にはヘッダー名だけを表示しています。この読み取り許可は値の送信先を制限しません。ヘッダーの外部送信がオフでも、JavaScriptは値を送信するボディに含められます。",
    "Only names are shown here. Read access does not limit where these values may be sent. JavaScript can put them in outgoing bodies even when external header forwarding is off."
  ],
  "WD_BINDING_DETAIL": [
    "この許可は、上のバージョンとプラグインの現在の設定が対象です。プラグインの内容、設定、送信先が変わると無効になります。",
    "This permission applies to the version above and the plugin’s current settings. Changes to the plugin, its settings or destination revoke it."
  ],
  "WD_BINDING_LOCAL_DETAIL": [
    "この許可は、上のバージョンとプラグインの現在の設定が対象です。プラグインの内容や設定が変わると無効になります。",
    "This permission applies to the version above and the plugin’s current settings. Changes to the plugin or its settings revoke it."
  ]
};
for (const lang of ['ja', 'en'] as const) {
 const i = lang === 'ja' ? 0 : 1;
 const t = (key: keyof typeof dangerousCopy) => dangerousCopy[key][i];
 for (const external of [true, false]) {
  const content = section('',notice('warn','Dangerous'),t(external ? 'WD_EXTERNAL_RISK' : 'WD_SCRIPT_RISK'))
   +section(lang==='ja'?'有効にする権限':'Permission to enable',row(external?(lang==='ja'?'元のヘッダーを外部に送る':'Send original headers externally'):(lang==='ja'?'JavaScriptにヘッダーの読み取りを許可':'Allow JavaScript to read headers'))+row(lang==='ja'?'プラグイン':'Plugin','Account result')+row(lang==='ja'?'バージョン':'Version','1.0.0'))
   +(external?section(lang==='ja'?'送信先':'Destination',row(lang==='ja'?'ホスト':'Host','collector.example.org')):'')
   +section(t(external?'WD_EXTERNAL_HEADERS':'WD_SCRIPT_HEADERS'),row('Authorization')+row('Cookie'),[t(external?'WD_EXTERNAL_PRIVACY':'WD_SCRIPT_PRIVACY'),t(external?'WD_BINDING_DETAIL':'WD_BINDING_LOCAL_DETAIL')].join(lang==='ja'?'':' '));
  const name = `dangerous${external?'':'-script'}${lang==='en'?'-en':''}`;
  await Bun.write(`${base}/mocks/${name}.html`,page(t(external?'WD_EXTERNAL_TITLE':'WD_SCRIPT_TITLE'),content,{back:lang==='ja'?'キャンセル':'Cancel',action:lang==='ja'?'有効にする':'Enable',sheet:true,lang}));
 }
}
console.log('Built shared catalog and screen mocks, including Japanese/English Dangerous confirmation.');
