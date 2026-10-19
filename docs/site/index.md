---
title: Interceptor Plugin 作者向けドキュメント
description: Interceptor Pluginの現在の実装範囲（取り込み・編集・合成データでのドライラン）と今後の予定
---

# Interceptor Plugin 作者向けドキュメント

Interceptorはアプリとサーバーの間のネットワーク通信を確認するためのアプリです。Interceptor PluginはInterceptorにJavaScriptで書いた独自の処理を追加するための仕組みです。作者はJavaScriptの処理と、プラグインの情報を持つマニフェストをパッケージJSONにまとめ、Interceptorへ取り込みます。

::: info 開発中のプレビュー
このガイドは、アプリの開発ブランチ `develop` で実装済みのPlugin基盤に合わせて書いています。現時点のアプリでできるのは、Pluginの**取り込み・保管・ソース編集・合成データでの試し実行**までです。実際の通信には作用せず、何も送信しません。仕様は予告なく変わる可能性があります。
:::

将来は、リクエストにテスト用のヘッダーを付ける、レスポンスの値を差し替える、特定のエラーを検知して通知するといった使い方を想定しています。ショートカットから選んだ処理を任意に起動する使い方も検討します。

FridaのHookを参考に、対象の通信とコールバックを登録する形にします。リクエストとレスポンスにそれぞれ `onEnter` / `onLeave` を設け、転送前の変更と転送後の後処理を書き分けます。[フック登録の設計案](/reference/javascript.md#hook-registration)にコード例を載せています。

対象のホスト・パス・メソッドと、その通信に対するHookを `Interceptor.attach` で指定する設計です。Interceptorが条件を照合するため、Hookの中で同じ条件を判定し直す必要はありません。[通信条件とフック呼び出し](/reference/javascript.md#match-gating)と[プラグインの例](/examples.md#plugin-example)を参照してください。この登録APIは未実装です。

## 通信とフックの位置

次の図は将来JSを呼びたい位置を示した概念図です。**図にある4つの通信フックはすべて未実装です。** 現在の `onRequest` / `onResponse` は合成データでの手動テスト用で、この通信経路では呼ばれません。

<figure class="plugin-flow-figure">
  <div class="plugin-flow-scroll" tabindex="0" aria-label="通信とフックの位置。狭い画面では横にスクロールできます">
    <img class="plugin-flow-light" src="/diagrams/plugin-hooks-light.svg" alt="未実装のフックの設計。リクエストはクライアントからInterceptorを経由してサーバーへ、レスポンスは逆向きに流れます。1 request.onEnterは送信前、2 request.onLeaveは送信後、3 response.onEnterは返却前、4 response.onLeaveは返却後に呼びます。" />
    <img class="plugin-flow-dark" src="/diagrams/plugin-hooks-dark.svg" alt="未実装のフックの設計。リクエストはクライアントからInterceptorを経由してサーバーへ、レスポンスは逆向きに流れます。1 request.onEnterは送信前、2 request.onLeaveは送信後、3 response.onEnterは返却前、4 response.onLeaveは返却後に呼びます。" />
  </div>
  <figcaption>青いカードは転送前に内容を変更できるHook、破線の先のカードは転送後の後処理です。番号は下の説明に対応します。図はHookの位置を示すもので、4つ全体の実行順や相手の受信・処理を保証しません。狭い画面では横にスクロールできます。</figcaption>
</figure>

## JSを呼ぶタイミング

リクエストはアプリからサーバーへの要求、レスポンスはサーバーからアプリへの応答です。ここでいう「元のアプリ」は、その通信を始めたアプリを指します。

今後の用途を、JSを呼ぶタイミングごとに説明します。**以下の5つはいずれも現在のアプリではまだ実行できません。** 現在使えるAPIの説明と、これらの構想を区別して読んでください。

「送った後」「返した後」をどの転送完了で判断するかは未設計で、相手が受信・処理したことまで保証するものではありません。

### 1. request.onEnter {#_1-リクエストをサーバーへ送る前}

リクエストをサーバーへ送る前に呼び、送信内容を変更するためのフックです。たとえば、ヘッダーやクエリ、JSON本文にテスト用の値を設定する用途を想定しています。

[`request.onEnter` の記述例](/reference/javascript.md#before-request)

### 2. request.onLeave {#_2-リクエストをサーバーへ送った後}

リクエストをサーバーへ送った後に呼び、送信した内容に応じて後処理するためのフックです。たとえば、特定のリクエストを検知して通知する用途を想定しています。この段階から、送信済みのリクエストをさかのぼって変更することはできません。

[`request.onLeave` の記述例](/reference/javascript.md#after-request)

### 3. response.onEnter {#_3-レスポンスを受け取り、元のアプリへ返す前}

サーバーからレスポンスを受け取り、元のアプリへ返す前に呼ぶフックです。返却する内容を変更するために使います。たとえば、JSON本文の値をテスト用の値に差し替える用途を想定しています。

レスポンスの書き換えは技術的には可能ですが、対象データを元のアプリへ転送する前に保留し、JSの結果を反映する仕組みが必要です。大きな本文やストリーミング、圧縮、待ち時間の上限などは、対応範囲をこれから設計します。

[`response.onEnter` の記述例](/reference/javascript.md#before-response)

### 4. response.onLeave {#_4-レスポンスを元のアプリへ返した後}

レスポンスを元のアプリへ返した後に呼び、返却した内容に応じて後処理するためのフックです。たとえば、特定のエラーレスポンスを検知して通知する用途を想定しています。この段階から、返却済みのレスポンスをさかのぼって変更することはできません。

[`response.onLeave` の記述例](/reference/javascript.md#after-response)

### 5. 利用者が任意に起動したとき

通信の発生を待たず、選んだ処理を実行するためのタイミングです。たとえば、ホーム画面に置いたショートカットから、入力データを整形する処理を呼ぶ使い方を検討しています。

この手動実行は現在の合成データでのテストとは別の機能案です。ショートカットから渡す入力、結果の返し方、実行する関数の名前や許可、アプリを開く必要があるかは未定です。

[フックの対応状況と未確定の仕様](/reference/javascript.md#manual)

## 現在のPluginで試せること

このガイドはInterceptorに取り込んで試すJavaScriptのプラグインを作るための文書です。JavaScriptの関数・オブジェクト・条件分岐、JSONの基本構造と、ターミナルでコマンドを実行する操作を前提にしています。配布する場合は静的ファイルをHTTPSで公開する準備も必要です。

Pluginの作者は、`onRequest` または `onResponse` というフック（JavaScriptの関数）を書き、マニフェストと組み合わせたパッケージとしてアプリに取り込みます。引数・コード例・試し方は[`onRequest` の書き方](/reference/javascript.md#onrequest)と[`onResponse` の書き方](/reference/javascript.md#onresponse)を参照してください。

このガイドで使う主な言葉は次のとおりです。

- フック: ソースに定義する `onRequest` と `onResponse` の関数です。
- マニフェスト: プラグインの `id`、`name`、`version`、対象とする通信、読み取りの宣言などを書く部分です。
- パッケージ: `manifest` と `source`（フックを含むJavaScript）の2つだけを持つJSONファイルです。
- リビジョン: パッケージの内容を区別して保存するための識別値です。ソースを編集して保存すると、新しいリビジョンができます。
- アクション: フックが返す `actions` の要素です。現在はアプリ上に表示されるだけです。
- ドライラン: アプリのスクリプト詳細画面で、自分でフックを選んで実行する試し実行です。画面では「合成データでのテスト」と表示されます。入力はテスト用に作られた合成データで、保存済みの通信は使いません。
- リポジトリ: 静的なHTTPSの `repository.json` と、その隣に置くパッケージファイルです。

## このガイドの基準

- アプリのソース: [`qtmleap/Interceptor` の `d3b9e05`](https://github.com/qtmleap/Interceptor/tree/d3b9e05db68cd4283a9874df6629313ad39174d5)（`develop`、コミット `d3b9e05db68cd4283a9874df6629313ad39174d5`）
- 公式の作者向けテンプレート: [qtmleap/Interceptor-Plugins](https://github.com/qtmleap/Interceptor-Plugins)

現在のAPIの数値や挙動は上記コミットのソースから確認したものです。以降のコミットで変わることがあります。冒頭の用途は今後の構想で、このコミットで使える機能とは別です。

## 実装済みと未実装

| 項目 | 状況 |
| --- | --- |
| パッケージ（`{manifest, source}` のJSON）の検証・取り込み・保管 | 実装済み |
| 静的HTTPSリポジトリ（`repository.json`）の追加・更新と、任意のEd25519署名 | 実装済み |
| ソースの表示・編集（編集のたびに新しいリビジョン） | 実装済み |
| QuickJSによる合成データでの明示的なドライラン | 実装済み |
| Bunでの鍵生成・配布用JSON生成 | [このガイドの生成スクリプト](/guide/distribution.md)で対応 |
| 実際のキャプチャに対するフック実行 | 未実装 |
| ホスト・メソッド・パスの条件照合によるHook呼び出しの絞り込み | 未実装・呼び出し前に照合する設計 |
| サーバー送信前のリクエスト変更・アプリ返却前のレスポンス変更 | 未実装・`request.onEnter` / `response.onEnter` の設計案を掲載 |
| JSON本文の操作（`rewriteJsonBody`） | 未実装・実行環境が提供する組み込みAPIとして設計 |
| 送信完了後・返却完了後の後処理 | 未実装・完了時点の定義は未設計 |
| ショートカット／ホーム画面からの任意実行 | 将来の機能案・未実装 |
| 保存済み通信の読み取り・`read` に基づくデータの絞り込み | 未実装 |
| 実行許可（グラント） | 未実装 |
| Packet Tunnelでの自動実行 | 未実装 |
| Webhookの配送・再試行・アウトボックス | 未実装 |
| 署名鍵のローテーション | 未実装 |

「未実装」の行は、現在は動作しません。

## 読む順序

1. [はじめての作成](/guide/getting-started.md): フックとパッケージを作り、ドライランする
2. [権限とデータの共有](/guide/permissions.md): 現在の範囲と、将来の許可について
3. [マニフェスト](/reference/manifest.md): 現在の項目と上限
4. [JavaScript](/reference/javascript.md): フック、合成入力、実行制限
5. [Webhook](/reference/webhook.md): 将来の機能（未実装）
6. [サンプル](/examples.md): ダウンロードできるJSON
7. [配布](/guide/distribution.md) / [トラブルシューティング](/troubleshooting.md)

<style>
.plugin-flow-scroll {
  overflow-x: auto;
  border: 1px solid var(--vp-c-divider);
  border-radius: 16px;
}
.plugin-flow-scroll img {
  display: block;
  width: 100%;
  min-width: 620px;
  max-width: none;
  margin: 0;
}
.plugin-flow-scroll .plugin-flow-dark { display: none; }
.dark .plugin-flow-scroll .plugin-flow-light { display: none; }
.dark .plugin-flow-scroll .plugin-flow-dark { display: block; }
.plugin-flow-figure figcaption {
  margin-top: 12px;
  color: var(--vp-c-text-2);
  font-size: 14px;
  line-height: 1.7;
}
</style>
