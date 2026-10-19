---
title: はじめての作成
description: フックを書き、パッケージJSONを作って、アプリで合成データのドライランをするまで
---

# はじめての作成

::: info 開発中のプレビュー
現在できるのは、パッケージを作ってアプリへ取り込み、ソースを編集し、**合成データ**で試し実行することまでです。実際の通信にフックは呼ばれず、Webhookも送信されません。
:::

## 流れ

この手順ではパソコンでパッケージを作り、対応する開発版のInterceptorで試します。対象は[基準コミット](/#このガイドの基準)のPlugin機能を含むアプリです。設定に「プラグイン」がないアプリでは、この手順を使えません。

このガイドは対応するアプリを入手済みの方向けです。2026年10月19日時点で、[GitHub Releases](https://github.com/qtmleap/Interceptor/releases)に配布用の実行ファイルは公開されていません。対応版の入手先はプロジェクトの管理者に確認してください。アプリ本体を自分でビルドする場合はXcodeが必要ですが、Pluginのパッケージや署名付き配布情報の作成には使いません。

Bunはパソコン上でJavaScriptやTypeScriptを実行するツールです。未導入なら[Bun公式のインストール手順](https://bun.sh/docs/installation)に従い、ターミナルで `bun --version` がバージョンを表示することを確認してください。このガイドのコード例はBun 1.4.2で動作確認しています。

1. フックとして `onRequest` または `onResponse` を書く
2. マニフェストと組み合わせて、`{manifest, source}` のJSONファイル（パッケージ）にする
3. アプリへ取り込む。取り込んだ直後のリビジョンは無効で、コードは実行されない
4. アプリのスクリプト詳細画面で、実行するフックを自分で選び、合成データでドライランする

## 1. 最小のプラグイン（アクションなし）

アクションを返さないプラグインはエンドポイント名（`endpointBindings`）が0個でも作れます。

```javascript
function onRequest(event, config) {
  return { actions: [] };
}
```

フックの返り値は必ず `{ actions: [...] }` の形です。アクションを返さないときは`actions` を空配列にします。

## 2. パッケージJSONを作る

パッケージは UTF-8 の JSON で、キーは `manifest` と `source` の2つだけです。`source` にはフックのJavaScriptをJSON文字列として入れるため、手で書かず、Bunで `JSON.stringify` を使って作ります。

ターミナルで作業用フォルダを作り、そのフォルダへ移動します。

```sh
mkdir my-first-plugin
cd my-first-plugin
```

この最小例は対象のホストだけを宣言します。将来の設計では、ホスト・メソッド・パスの条件を `Interceptor.attach` の第1引数に書き、Interceptorがコールバックの呼び出し前に照合します。詳しくは[JavaScript](/reference/javascript.md#match-gating)を参照してください。通信を書き換える例は[サンプル](/examples.md#plugin-example)にあります。現在のドライランは手動で選んだフックを絞り込みなしで実行します。

エディタで、このフォルダの中に `build.ts` を作り、次の内容を保存してください。最初の関数は `source` の文字列に含めてあるため、別のJavaScriptファイルを作る必要はありません。

```ts
const idFile = Bun.file("plugin-id.txt");
const id = (await idFile.exists())
  ? (await idFile.text()).trim()
  : crypto.randomUUID();
await Bun.write(idFile, id + "\n");

const source = `function onRequest(event, config) {
  return { actions: [] };
}
`;

const pkg = {
  manifest: {
    schemaVersion: 1,
    id,
    name: "My first plugin",
    version: "1.0.0",
    subscriptions: [
      { phase: "request.completed", match: { hosts: ["example.com"] } },
    ],
    read: {
      metadata: ["method", "host"],
      headers: [],
      queryKeys: [],
      body: { mode: "none" },
    },
    endpointBindings: [],
    settings: {},
  },
  source,
};

await Bun.write("my-first-plugin.json", JSON.stringify(pkg, null, 2) + "\n");
```

同じフォルダで次のコマンドを実行します。

```sh
bun build.ts
```

成功すると、同じフォルダに `my-first-plugin.json` と `plugin-id.txt` ができます。アプリに取り込むのは `my-first-plugin.json` です。`build.ts` はパソコンでJSONを作るためのファイルで、アプリには取り込みません。

- `plugin-id.txt` は、このプラグインを識別するUUIDを保存するファイルです。初回だけUUIDを生成し、次からは同じ値を読み込みます。同じプラグインを更新するときは、このファイルを残して `bun build.ts` を再実行してください。別のプラグインを作る場合は、別の作業フォルダを使います。
- 同じプラグインを更新するときは、`id` をそのままにして、`version` を SemVer（例 `1.0.1`）で上げることを勧めます。
- パッケージの**リビジョンはパッケージの正確なバイト列の SHA-256** で決まります。JSONを整形し直しただけでも、バイト列が変わるため別のリビジョンになります。
- 項目と上限は[マニフェスト](/reference/manifest.md)を参照してください。

## 3. アクションを返す例

[サンプル](/examples.md)でダウンロードできるパッケージは、プレビュー用の送信先 `config.endpoints.preview` を宛先にしたアクションを返します。コピーして使うときは、必ず `manifest.id` を新しいUUIDに置き換えてください。アクションはアプリ上に表示されるだけで、送信されません。

## 4. 取り込みとドライラン

1. `my-first-plugin.json` を、Interceptorを使う端末のファイル選択画面から選べる場所へコピーします。iCloud Driveなど、端末の「ファイル」アプリで開ける場所を使ってください。
2. Interceptorの「設定」→「プラグイン」を開き、右上の「＋」→「ファイルから読み込む」で `my-first-plugin.json` を選びます。成功すると「スクリプト」の一覧に `My first plugin` が表示されます。
3. `My first plugin` を開きます。このスクリプト詳細画面には「ソース」と「合成データでのテスト」があります。ソースを編集した場合は、右上の「保存」を押してからテストしてください。
4. 「フック」で「リクエスト」（`onRequest`）を選びます。「レスポンス」は `onResponse` に対応します。マニフェストの `subscriptions` をもとに自動で選ばれることはありません。
5. 入力欄は[合成データの既定値](/reference/javascript.md#合成入力の既定値)のまま、「合成データでテスト」を押します。実際に保存された通信は使われません。
6. この最小例では「検証済みアクション」「未送信」「スクリプトはアクションを返しませんでした。」と表示されれば成功です。アクションが0件なのは、フックが `{ actions: [] }` を返すためです。エラーの表示とは異なります。

[サンプル](/examples.md)のJSONも同じ方法で取り込めます。リクエストのサンプルは「リクエスト」、レスポンスのサンプルは「レスポンス」を選ぶと、既定入力では1件のアクションとそのJSONが表示されます。入力欄のJSONを編集すれば、別の合成データでも試せます。[配布](/guide/distribution.md)のリポジトリ経由で取り込むこともできます。

選んだフックがソースに定義されていない場合は、ドライランがエラーになります。詳しくは[トラブルシューティング](/troubleshooting.md)を参照してください。

## テンプレート

- 「設定」→「プラグイン」→「＋」→「サンプルスクリプトを作成」でも、`example.com` だけを対象にした、メタデータのみのテンプレートを作れます。
- 作者向けの公式テンプレートリポジトリ: [qtmleap/Interceptor-Plugins](https://github.com/qtmleap/Interceptor-Plugins)。パッケージの `source` は、現在はJavaScriptです。TypeScript を使うには、`source` に入れるJavaScriptを生成する別のビルド手順が必要です。その手順はこのガイドの対象外です。

## 次に読む

- [マニフェスト](/reference/manifest.md) / [JavaScript](/reference/javascript.md)
- [配布](/guide/distribution.md)
