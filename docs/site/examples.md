---
title: サンプル
description: プレビュー用のサンプル関数とダウンロードできるパッケージJSON
---

# サンプル

::: info 開発中のプレビュー
前半は `Interceptor.attach` を使うプラグインの設計例、後半は現在の合成テストで使えるパッケージです。`Interceptor.attach` と `rewriteJsonBody` は未実装です。後半の `config.endpoints.preview`（UUID `5e1d0c4a-0000-4000-8000-00000000a001`）は合成のダミー送信先で、**何も配送されません。**
:::

## プラグインの例 {#plugin-example}

<span id="multiple-registrations"></span>

検索APIのリクエストと、状態確認APIのレスポンスを書き換えるプラグインです。

- `api.example.com` の `POST /search`：送るJSONの検索件数と言語を変更します。
- `api.example.com` の `GET /status`：返すJSONをメンテナンス表示用に変更します。

どちらも `request.onEnter` / `request.onLeave` / `response.onEnter` / `response.onLeave` を持ちます。条件は `Interceptor.attach` の第1引数に書くので、Hook内でホスト・パス・メソッドを判定し直しません。

::: warning 現在のアプリでは実行できません
以下は設計例です。現在のアプリには `Interceptor.attach` も `rewriteJsonBody` もないため、このソースを合成テストに貼り付けても動きません。`rewriteJsonBody` は実行環境が提供する想定の組み込み関数で、ソースに定義や import は書きません。詳しくは[rewriteJsonBody](/reference/javascript.md#rewrite-json-body)を参照してください。
:::

```javascript
Interceptor.attach({
  hosts: ["api.example.com"],
  methods: ["POST"],
  path: { kind: "exact", value: "/search" }
}, {
  request: {
    onEnter(request) {
      rewriteJsonBody(request, (data) => {
        data.limit = 5;
        data.locale = "ja-JP";
      });
    },
    onLeave(request) {
      // 検索リクエストを送った後の処理を書く
    }
  },
  response: {
    onEnter(response) {
      // 検索結果を元のアプリへ返す前の処理を書く
    },
    onLeave(response) {
      // 検索結果を元のアプリへ返した後の処理を書く
    }
  }
});

Interceptor.attach({
  hosts: ["api.example.com"],
  methods: ["GET"],
  path: { kind: "exact", value: "/status" }
}, {
  request: {
    onEnter(request) {
      // 状態確認リクエストを送る前の処理を書く
    },
    onLeave(request) {
      // 状態確認リクエストを送った後の処理を書く
    }
  },
  response: {
    onEnter(response) {
      rewriteJsonBody(response, (data) => {
        data.maintenance = true;
        data.message = "ただいまメンテナンス中です";
      });
    },
    onLeave(response) {
      // 状態確認レスポンスを元のアプリへ返した後の処理を書く
    }
  }
});
```

このソース全体を1つの `source` に入れ、1つのマニフェストと組み合わせて配布する想定です。`manifest.id` と `version` はプラグイン全体で1組持ち、`Interceptor.attach` ごとには増やしません。検索処理と状態確認処理は、同じプラグインの更新としてリリースします。

条件が重なる `Interceptor.attach` の実行順や変更結果の重ね方、呼び出し回数の上限、現行マニフェストとの統合・移行方法は未確定です。現在の `subscriptions` の上限がそのまま新しい上限になるわけではありません。

## 合成テスト用のパッケージ {#synthetic-packages}

以下の2つのパッケージは現在の合成テスト用です。どちらも `read` はメタデータのみで、`body` は `none` です。使うときは、`manifest.id` を新しいUUIDに置き換えてください。UUIDは `bun -e 'console.log(crypto.randomUUID())'` で生成できます。同じプラグインを更新するときは、`id` を保ち、`version` を上げます。

### リクエストのサンプル

`onRequest` は`eventId`、`method`、`host` を含むアクションを返します。このパッケージの現行マニフェストは、ホスト `example.com`・メソッド `GET`・完全一致のパス `/synthetic` を宣言します。現在の合成テストはこの宣言で絞り込みません。新しい登録APIでは、[各登録の条件](/reference/javascript.md#match-gating)を呼び出し前に照合する設計です。

```javascript
function onRequest(event, config) {
  return {
    actions: [{
      type: "webhook",
      endpointId: config.endpoints.preview,
      json: {
        eventId: event.id,
        method: event.request.method,
        host: event.request.host
      }
    }]
  };
}
```

[ダウンロード](/examples/request-alert.json)

<<< @/public/examples/request-alert.json

### レスポンスのサンプル

`onResponse` は、`status` が500以上なら `eventId` と `status` を含むアクションを返し、それ以外は `{ actions: [] }` を返します。合成の既定入力は `status: 503` です。

```javascript
function onResponse(event, config) {
  if (event.response.status < 500) return { actions: [] };
  return {
    actions: [{
      type: "webhook",
      endpointId: config.endpoints.preview,
      json: { eventId: event.id, status: event.response.status }
    }]
  };
}
```

[ダウンロード](/examples/response-alert.json)

<<< @/public/examples/response-alert.json

## 補足

- 現行マニフェストの `match` は検証されて保存される宣言で、ドライランの入力を絞り込みません。実行するフックは手動で選びます。新しい登録APIでの照合は[JavaScript](/reference/javascript.md#match-gating)を参照してください。
- 入力の形は[JavaScript](/reference/javascript.md#合成入力の既定値)、項目は[マニフェスト](/reference/manifest.md)を参照してください。
