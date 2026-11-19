---
title: JavaScript リファレンス
description: フック、合成入力の既定値、実行制限、結果の形
---

# JavaScript リファレンス

::: info 開発中のプレビュー
スクリプトが実行されるのは、アプリのスクリプト詳細画面で「合成データでテスト」を押したときだけです。このガイドではこの試し実行をドライランと呼びます。入力は合成データです。取り込み・保存・編集ではコードは実行されません。
:::

## 現在のフック {#current-hooks}

フックはパッケージJSONの `source` に書くトップレベルの関数です。現在あるのは `onRequest` と `onResponse` の2つで、どちらか一方だけでも、両方定義しても構いません。引数 `event` と `config` には、JSONのトップレベルのオブジェクトがそのまま渡されます。

どちらのフックを実行するかは、ドライランのときに手動で選びます。選んだ名前の関数が `source` になければエラーです。マニフェストの `phase` / `match` / `read` は検証されて保存されるだけの宣言で、フックの選択や合成入力の絞り込みには使われません。

以下の手順は、パッケージを作って取り込み済みであることが前提です。先に[はじめての作成](/guide/getting-started.md)を済ませてください。

## 通信条件とフック呼び出し {#match-gating}

実通信では、**Interceptorが登録ごとの対象条件を照合し、一致した登録のHookだけを呼ぶ**設計です。ホスト・メソッド・パスの照合はHookの呼び出し前に済ませるため、`onRequest` の先頭で同じ条件を `if` で判定する必要はありません。この呼び出し制御は未実装です。

条件は `Interceptor.attach` の第1引数に書きます。1回の登録は対象条件1組と、その通信に対する4つのHookをまとめたものです。たとえば、次の条件は `example.com` の `GET /synthetic` を対象とします。

```json
{
  "hosts": ["example.com"],
  "methods": ["GET"],
  "path": { "kind": "exact", "value": "/synthetic" }
}
```

1つの登録では指定したホスト・メソッド・パスのすべてに一致する必要があります。ホストやメソッドに複数の候補を書く場合、その項目内ではどれか1つに一致すれば対象です。`hosts` は必須で、`methods` や `path` を省略した項目は制限しません。`path.kind` は完全一致の `exact`、または先頭一致の `prefix` とする設計です。

- `example.com` の `GET /synthetic`：Hookを呼びます。
- 同じホスト・パスでも `POST`：Hookを呼びません。
- 同じメソッド・パスでも別のホスト：Hookを呼びません。
- 同じホスト・メソッドでも `/other`：Hookを呼びません。

対象外の通信ではHook自体を呼びません。Hookを実行したうえで `{ actions: [] }` を返す動作とは異なります。条件に合った後のJSONの書き換えや、本文の値に応じた処理はHookに書きます。

現在の合成テストは、作者が手動でHookを選んで実行する機能で、この照合を通しません。以下の `onRequest` を手動実行する場合は、入力のホスト・メソッド・パスを変えても関数が呼ばれます。`event.request` を含む合成入力の形は保ってください。

条件と4つのHookは `Interceptor.attach` で指定します。[プラグインの例](/examples.md#plugin-example)を参照してください。

現行の `subscriptions[].match` は現在のプラグイン基盤で検証・保存する宣言です。新しい登録の振り分け表として使う仕様ではありません。現行マニフェストと新しい登録形式の統合・移行方法は未確定です。

## onRequest(event, config) {#onrequest}

合成のリクエストイベントを受け取り、表示用のWebhookアクションを返します。

- `event`: [合成入力の既定値](#合成入力の既定値)の `onRequest` 用イベント。
- `config`: 同じ節の `config`。`config.endpoints.preview` は、既定の編集可能な合成configに入っています。マニフェストから作られるものではありません。

```javascript
function onRequest(event, config) {
  return {
    actions: [{
      type: "webhook",
      endpointId: config.endpoints.preview,
      json: { eventId: event.id, method: event.request.method, host: event.request.host }
    }]
  };
}
```

試す手順は次のとおりです。

1. 取り込んだプラグインのスクリプト詳細画面で、「ソース」に上のコードを貼り付けて「保存」を押します。
2. 「フック」で「リクエスト」を選びます。イベントとconfigは初回表示では入力済みです。[合成入力の既定値](#合成入力の既定値)と同じ内容であることを確認し、編集済みなら既定値に戻してから「合成データでテスト」を押します。
3. アクションが1件表示され、JSONは次の内容になります。宛先は `config.endpoints.preview` の値です。

```json
{ "eventId": "00000000-0000-4000-8000-000000000001", "method": "GET", "host": "example.com" }
```

現在の手動テストでイベント入力の `"method": "GET"` を `"method": "POST"` に変えて再実行すると、関数は実行され、`method` が `"POST"` のアクションを1件返します。実通信で目指す[条件不一致ならHookを呼ばない動作](#match-gating)とは区別してください。

## onResponse(event, config) {#onresponse}

合成のレスポンスイベントを受け取り、表示用のWebhookアクションを返します。

- `event`: [合成入力の既定値](#合成入力の既定値)の `onResponse` 用イベント。
- `config`: `onRequest` と同じ。`config.endpoints.preview` は既定の編集可能な合成configに入っており、マニフェストから作られるものではありません。

```javascript
function onResponse(event, config) {
  const status = event.response && event.response.status;
  if (typeof status !== "number" || status < 500 || status > 599) return { actions: [] };
  return {
    actions: [{
      type: "webhook",
      endpointId: config.endpoints.preview,
      json: { eventId: event.id, status: status }
    }]
  };
}
```

試す手順は次のとおりです。

1. 取り込んだプラグインのスクリプト詳細画面で、「ソース」に上のコードを貼り付けて「保存」を押します。
2. 「フック」で「レスポンス」を選びます。イベントとconfigは初回表示では入力済みです。[合成入力の既定値](#合成入力の既定値)と同じ内容であることを確認し、編集済みなら既定値に戻してから「合成データでテスト」を押します。
3. アクションが1件表示され、JSONは次の内容になります。宛先は `config.endpoints.preview` の値です。

```json
{ "eventId": "00000000-0000-4000-8000-000000000003", "status": 503 }
```

続いてイベント入力の `"status": 503` を `"status": 200` に書き換えて再度テストすると、アクションは0件（`{ actions: [] }`）になります。

どちらのフックも、返すのは表示用のアクションだけです。送信もキュー投入もされず、実際の通信も変わりません。

## 合成入力の既定値

::: warning 最終的なライブデータの形ではありません
以下はドライラン用の合成入力の既定値です。実際のキャプチャに対するイベントのスキーマは確定しておらず、将来変わる可能性があります。
:::

`onRequest` に渡す `event` は次の内容です。

```json
{
  "id": "00000000-0000-4000-8000-000000000001",
  "exchangeID": "00000000-0000-4000-8000-000000000002",
  "phase": "request.completed",
  "time": "2026-01-01T00:00:00Z",
  "request": { "method": "GET", "host": "example.com", "path": "/synthetic" }
}
```

`onResponse` に渡す `event` は次の内容です。

```json
{
  "id": "00000000-0000-4000-8000-000000000003",
  "exchangeID": "00000000-0000-4000-8000-000000000002",
  "phase": "response.completed",
  "time": "2026-01-01T00:00:01Z",
  "request": { "method": "GET", "host": "example.com", "path": "/synthetic" },
  "response": { "status": 503 }
}
```

対応する `config` は次の内容です。

```json
{
  "endpoints": { "preview": "5e1d0c4a-0000-4000-8000-00000000a001" }
}
```

`config.endpoints.preview` は合成のダミー送信先です。何も配送されません。マニフェストの `settings` は `config` に自動では入りません。

## 返り値

現在の合成テスト用APIの返り値は `actions` だけを持つオブジェクトです。表せるのは表示用のWebhookアクションだけです。リクエストやレスポンスを置き換える返り値は定義されていません。引数 `event` の内容を書き換えても、実際の通信に反映する仕組みはありません。

- `actions` は最大2件。各要素のキーは `type`（`"webhook"`）、`endpointId`（UUID）、`json` の3つだけです。
- アクションは表示されるだけで、キューにも配送にも入りません。
- アクションなしは `{ actions: [] }` です。

## 実行環境と制限

フックはQuickJSというJavaScript実行環境で、同期的なJavaScriptとして実行されます。`import`、`fetch`、DOM、ファイル、ネイティブ呼び出し、タイマーはありません。

| 項目 | 上限 |
| --- | --- |
| ソース評価から結果検証までの協調中断予算 | 50 ms |
| ヒープ | 8 MiB |
| スタック | 256 KiB |
| ソース | 128 KiB |
| イベントJSON | 64 KiB |
| config JSON | 8 KiB |
| 結果JSON | 32 KiB、深さ32 |
| アクション数 | 2 |

- 50 msはVMの後処理を含めた応答時間の保証ではありません。
- 呼び出しごとに新しいVMで実行され、状態は引き継がれません。
- ドライランの実行中にもう一度ドライランすると、待たされることなく、すぐに `busy` で拒否されます。待ち行列はありません。
- 非有限の数値、`BigInt`、関数、thenable（Promise含む）、循環参照は結果として無効です。

## フックの実行タイミング {#future-hooks}

リクエストとレスポンスにそれぞれ `onEnter` / `onLeave` を用意する設計です。リクエストではサーバーへの送信前と送信後、レスポンスでは元のアプリへの返却前と返却後に呼びます。内容を書き換える処理は `onEnter`、転送済みの内容を確認する後処理は `onLeave` に書きます。

**以下は未実装のAPIの設計案です。** 現在の合成テスト用 `onRequest` / `onResponse` とは別で、その置き換えや別名ではありません。合成イベントの `phase`（`request.completed` など）を変えても、この4つのフックを実行することはできません。

### フックの登録方法 {#hook-registration}

[Fridaの `Interceptor.attach`](https://frida.re/docs/javascript-api/#interceptor)のように、対象とコールバックを組み合わせて登録する形にします。Interceptor Pluginでは `request` と `response` にそれぞれ `onEnter` / `onLeave` を書き、4つのタイミングを区別します。

::: warning 現在のアプリでは実行できません
以下はInterceptor PluginのAPIの設計案で、Frida自体のAPIではありません。現在の実行環境には `Interceptor.attach` がないため、このソースを合成テストへ貼り付けても動きません。本文の操作例も説明用のデータ形式を仮定しています。
:::

```javascript
Interceptor.attach({
  hosts: ["example.com"],
  methods: ["GET"],
  path: { kind: "exact", value: "/synthetic" }
}, {
  request: {
    onEnter(request) {
      // 1. サーバーへ送る前：リクエストを確認・変更する
    },
    onLeave(request) {
      // 2. サーバーへ送った後：送信した内容をもとに後処理する
    }
  },
  response: {
    onEnter(response) {
      // 3. 元のアプリへ返す前：レスポンスを確認・変更する
    },
    onLeave(response) {
      // 4. 元のアプリへ返した後：返却した内容をもとに後処理する
    }
  }
});
```

第1引数はこの登録の[対象条件](#match-gating)、第2引数はこの登録に対応する4つのHookです。Fridaのようにネイティブ関数のアドレスを指定するものではありません。各Hookの引数 `request` / `response` は、それぞれの方向の通信データを表すオブジェクトとする想定です。参照できる具体的な項目やデータ形式は未確定です。

別の条件とHookを追加するときは、同じソースで `Interceptor.attach` をもう一度呼びます。配布・更新は、ソース全体を含むプラグイン単位です。

このページの `request.onEnter` などの表記は上の登録オブジェクト内での位置を示します。`request.onLeave` は送信したリクエストを、`response.onLeave` は返却したレスポンスを確認するためのコールバックです。Fridaの `onLeave(retval)` のように返り値を書き換える意味ではなく、転送済みの内容は変更できません。

以下の各コードは登録オブジェクトから該当するコールバックだけを抜き出したものです。JSON本文の書き換えには、実行環境が提供する想定の組み込み関数 [`rewriteJsonBody`](#rewrite-json-body) を使います。これは設計案で、実装済みの仕様ではありません。下の変更前後のJSONは読みやすく整形しています。

### rewriteJsonBody {#rewrite-json-body}

**API設計案です。現在のアプリには実装がなく、現在の合成VMにも存在しません。** `Interceptor.attach` も同様に使えません。

`rewriteJsonBody` は、実行環境がグローバルに提供する想定のJSON本文書き換え関数です。作者のソースで定義や import はしません。プラグインのソースからそのまま呼べる、Interceptor Plugin用のAPIです。

```javascript
rewriteJsonBody(message, update)
```

- `message.body` は、圧縮を展開し、UTF-8としてデコードした本文の文字列を想定しています。
- 使える場所は `request.onEnter` と `response.onEnter` だけです。`message` にはそのHookの引数（`request` または `response`）を渡します。
- `update(data)` は同期関数で、解析済みのオブジェクト `data` を直接変更します。返り値は無視します。Promiseなどのthenableを返す非同期処理には対応せず、エラーとします。
- `update` が正常に終了した後で、オブジェクトを `JSON.stringify` で本文に戻して差し替えます。
- 本文が存在しない、文字列でない、JSONでない、またはJSONの値が配列・`null`・数値などの場合は、`update` を呼ばず本文も変更しません。
- `update` の例外、`JSON.stringify` の失敗、thenable の返却では、元の本文を保ち、ヘルパーのエラーとして報告します。Hook全体の失敗時に通信をどう転送するか、UIでどう表示するかは未確定です。
- 返り値は `undefined` で、成功・スキップの状態は返しません。

`JSON.parse` / `JSON.stringify` を通すため、元の空白や改行は保たれず、JavaScriptで正確に表せない大きな整数は解析時に値が変わることがあります。`Content-Length` などの転送情報の更新や再圧縮はホスト側が担う想定ですが、方法は未確定です。既存の `body` を直接扱う本文APIも将来の設計案です。

### request.onEnter {#before-request}

リクエストをサーバーへ送る前に呼びます。`request` 内の `onEnter` に、送信前のリクエストを確認・変更する処理を書きます。

次の例は検索APIに送るJSON本文の `limit` を `20` から `5` に変更し、`locale` を追加します。`keyword` など、それ以外の項目は残します。

```javascript
onEnter(request) {
  rewriteJsonBody(request, (data) => {
    data.limit = 5;
    data.locale = "ja-JP";
  });
}
```

変更前のリクエスト本文:

```json
{
  "keyword": "coffee",
  "limit": 20
}
```

変更後にサーバーへ送る本文（この設計案の想定）:

```json
{
  "keyword": "coffee",
  "limit": 5,
  "locale": "ja-JP"
}
```

この例は `rewriteJsonBody` で本文を差し替える想定です。現在の合成テスト用の返り値 `{ actions: [...] }` では通信内容を書き換えられません。

### request.onLeave {#after-request}

リクエストをサーバーへ送った後に呼びます。`request` 内の `onLeave` に、送信した内容をもとに通知などの後処理を書きます。引数はリクエストを表し、サーバーからのレスポンスではありません。送信済みのリクエストは変更できません。

```text
onLeave(request) {
  // 例：送信したリクエストが通知対象の条件に合うか確認する
}
```

通知の発行方法や、後処理で使えるAPIは未確定です。

「送信後」をどの転送完了で判断するかは未設計です。サーバーが受信・処理したことまで保証するものではありません。

### response.onEnter {#before-response}

サーバーからレスポンスを受け取り、元のアプリへ返す前に呼びます。`response` 内の `onEnter` に、返却前のレスポンスを確認・変更する処理を書きます。

次の例はJSON本文の `maintenance` を `true` にし、`message` を差し替えます。サーバー側の実装を変えずに、元のアプリのメンテナンス表示を試す用途を想定しています。

```javascript
onEnter(response) {
  rewriteJsonBody(response, (data) => {
    data.maintenance = true;
    data.message = "ただいまメンテナンス中です";
  });
}
```

サーバーから受け取ったレスポンス本文:

```json
{
  "maintenance": false,
  "message": "通常営業中"
}
```

変更後に元のアプリへ返す本文（この設計案の想定）:

```json
{
  "maintenance": true,
  "message": "ただいまメンテナンス中です"
}
```

書き換えには、対象データを転送前に保留してJSの結果を反映する仕組みが必要です。実際の本文APIや反映方法、大きな本文やストリーミング、圧縮、待ち時間の上限などの対応範囲は未確定です。

### response.onLeave {#after-response}

レスポンスを元のアプリへ返した後に呼びます。`response` 内の `onLeave` に、返却した内容をもとにエラーの通知などの後処理を書きます。返却済みのレスポンスは変更できません。

```text
onLeave(response) {
  // 例：返却したレスポンスが通知対象のエラーか確認する
}
```

通知の発行方法や、後処理で使えるAPIは未確定です。

「返却後」をどの転送完了で判断するかは未設計です。元のアプリが受信・処理したことまで保証するものではありません。

### 共通の未確定事項

上の例では、本文の変更で必要になる `Content-Length` などの転送情報の更新をInterceptor側が担う想定です。プラグイン内で文字数から長さを計算したり、元の長さをそのまま使ったりしません。日本語などを含むUTF-8のバイト数は文字数と異なります。再圧縮を含め、転送情報を整合させる仕組みはこれから設計します。

`rewriteJsonBody` 内部で本文を差し替える条件は上の設計案のとおりです。部分的な転送や転送失敗の際にどのフックを呼ぶか、Hook全体の例外や時間切れの扱い、登録の有効期間、通信ごとの状態の持ち方は未設計です。条件が重なる `Interceptor.attach` の実行順や変更結果の重ね方、呼び出し回数の上限、現行の `phase`・`read`・実行許可との統合は未確定です。リクエストとレスポンスの転送が重なる場合を含め、4つのフック全体の実行順は保証しません。

### 任意実行（ショートカットなど） {#manual}

通信の発生を待たず、ショートカットなどから利用者が選んだ処理を実行する用途です。現在は将来の機能案で、手動実行用のフックはありません。関数名、入力、結果の返し方、許可、アプリを開く必要があるかは未定です。現在の合成データでのテストとは別の機能です。
