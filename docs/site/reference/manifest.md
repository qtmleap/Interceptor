---
title: マニフェスト リファレンス
description: 現在のマニフェスト（schemaVersion 1）の項目、検証ルール、上限
---

# マニフェスト リファレンス

::: info 開発中のプレビュー
ここに書く項目は、取り込み時に検証されて保存される宣言です。現時点ではフックの呼び出しを絞り込んだり、ドライランの入力を加工したりはしません。実際のキャプチャとの照合や権限の付与にも使われません。
:::

マニフェストはパッケージの `manifest` キーに入れるJSONオブジェクトです。プラグインの `id` や `version` に加えて、対象とする通信と読み取るデータの宣言を書きます。

現在は、マニフェストの宣言とドライランの実行が独立しています。

| 要素 | 宣言・定義するもの | 現在のドライランとの関係 |
| --- | --- | --- |
| `subscriptions` | 対象とする通信 | 入力を絞り込まず、フックも自動では選ばない |
| `read` | 読み取るデータ | 入力の項目を絞り込まない。アクセス許可にもならない |
| `endpointBindings` | 送信先を区別する名前 | 入力や送信先を自動では設定しない |
| `settings` | プラグインの設定情報 | 引数 `config` に自動では入らない |
| `onRequest` / `onResponse` | JavaScriptの処理 | アプリで手動選択した関数を実行する |

## 構造

`manifest` の必須キーは次の8つです。未知のキーと重複キーは拒否されます。任意の `author` と `summary` は後述します。

| キー | 内容 |
| --- | --- |
| `schemaVersion` | `1` |
| `id` | UUID |
| `name` | 1〜80文字・UTF-8で256バイト以内の、空でない1行の表示名 |
| `version` | SemVer 2.0.0（64バイトまで） |
| `subscriptions` | 1〜8件 |
| `read` | 読み取りの宣言 |
| `endpointBindings` | 0〜4件 |
| `settings` | オブジェクト |

任意: `author`、`summary`。

## subscriptions

`subscriptions` の各要素が対象とする通信を宣言します。各要素には `phase` と `match` を書きます。

ここで受け付ける4つの `phase` は、ヘッダーとメッセージ終端を区別する宣言です。これらの値を指定しても、通信の転送を待たせたり、内容を書き換えたりはできません。

新しいコールバックの設計では、リクエストとレスポンスを明示的な組にして、`request.onEnter` / `request.onLeave` / `response.onEnter` / `response.onLeave` の4つを使います。現在の `request.headers` / `request.completed` / `response.headers` / `response.completed` は、この4つへの対応ではありません。既存の `phase` を新しい設計へどう移行するかは未決定です。

- `phase`: `request.headers` / `request.completed` / `response.headers` / `response.completed`
- `match.hosts`（必須）: 1〜32件、重複なし。小文字のASCIIのみ（`a-z 0-9 -` とドット）。全体253バイト・各ラベル63バイトまでで、ラベル先頭・末尾のハイフンは不可です。IDNA変換や正規化はされません。
- `match.methods`（任意）: 1〜16件、重複なし。大文字のみ、各16文字まで（例 `GET`）。
- `match.path`（任意）: `{ "kind": "exact" | "prefix", "value": "/..." }`。`/` で始まり、1024バイトまで。非ASCII文字はpercent-encodeし、`%` の後には16進数2桁が必要です。
- `match.status`（任意）: `{ "min": 100〜599, "max": 100〜599 }`、`min <= max`。レスポンスのphaseでのみ指定できます。

### 呼び出し条件 {#match-conditions}

現在の `subscriptions[].match` は取り込み時に検証されて保存される宣言です。現在の合成データ専用のドライランでは、これを使って呼び出しを絞り込みません。

将来の設計では、呼び出し条件（`hosts` / `methods` / `path`）は `Interceptor.attach(条件, コールバック)` の第1引数に書き、Interceptorが4つのコールバックを呼ぶ前に照合します。

現行のパッケージでは、引き続き `subscriptions` を1〜8件指定する必要があります。新しい登録APIの設計によって、現在のスキーマの必須項目が変わるわけではありません。

`subscriptions` の1〜8件という上限は将来の `attach` の登録数の上限ではありません。登録数の上限と、現在のスキーマからの移行や統合の方法は未決定です。

詳しくは[JavaScript](/reference/javascript.md#match-gating)と[サンプル](/examples.md#plugin-example)を参照してください。

## read

`read` は、プラグインが読み取るデータの宣言です。

| キー | ルール |
| --- | --- |
| `metadata` | `method` / `host` / `status` / `path` から。重複なし |
| `headers` | 32件まで。大文字小文字を区別せず重複なし。各128バイトまで |
| `queryKeys` | 32件まで、重複なし、各128バイトまで |
| `body` | `{ "mode": "none" }` / `{ "mode": "raw" }` / `{ "mode": "jsonPointers", "pointers": [...] }` |

- `jsonPointers` のポインタは1〜32件、重複なし、各256文字まで、RFC 6901の形式です。`mode` が `none` と `raw` のときは `pointers` を付けられません。
- `subscriptions` で `request.headers` / `response.headers` のphaseを指定するときは、`body.mode` を `none` にします。

## endpointBindings

送信先を区別するための名前を宣言します。この宣言も形式を検証して保存するだけで、ドライランの入力や送信先は変わりません。名前は0〜4個、重複なしです。各名前は `[A-Za-z][A-Za-z0-9_]*` で32バイトまでです。アクションを返さないプラグインは0個で構いません。

## settings

オブジェクトで、JSONにして8 KiB以内、ネストは16段までです。ドライランでフックに渡される `config` には**自動では入りません**。

## author と summary

任意の表示用テキストです。

| キー | 文字数 | バイト数 |
| --- | --- | --- |
| `author` | 1〜80 | 256まで |
| `summary` | 1〜280 | 1024まで |

1行のプレーンテキストのみです。空文字、空白のみ、制御文字、書式文字（双方向制御を含む）、行・段落区切り、`null`、文字列以外は拒否されます。アプリでは未検証の公開者テキストとして表示され、本人確認にはなりません。**これらのキーを知らない古いクライアントは、未知のキーとしてパッケージを拒否します。**

## 例

```json
{
  "schemaVersion": 1,
  "id": "00000000-0000-4000-8000-000000000000",
  "name": "Sample",
  "version": "1.0.0",
  "subscriptions": [
    { "phase": "request.completed", "match": { "hosts": ["example.com"], "methods": ["GET"], "path": { "kind": "exact", "value": "/synthetic" } } }
  ],
  "read": { "metadata": ["method", "host"], "headers": [], "queryKeys": [], "body": { "mode": "none" } },
  "endpointBindings": ["preview"],
  "settings": {}
}
```

この `id` は例のための仮の値です。自分のプラグインでは新しいUUIDにしてください。

## パッケージ全体の上限

パッケージは256 KiBまで、`source` は128 KiBまでです。
