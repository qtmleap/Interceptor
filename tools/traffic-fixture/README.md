# traffic-fixture

Interceptor のプラグイン／通信テスト用ダミーサーバー (Hono + Cloudflare Workers)。
認証やレスポンス形式を切り替えて、プラグインの動作を確認できます。
公開の検証用サーバーです。実際の認証情報や個人情報を送らないでください。
受信したAuthorization・Cookieヘッダーはレスポンスに含めません。Workerのコードではリクエストの本文やヘッダーを保存しません。

## エンドポイント

| Method | Path | 内容 |
| --- | --- | --- |
| GET | `/`, `/health` | エンドポイント一覧 / `{"status":"ok"}` |
| GET | `/json` | `{"maintenance":false}` 固定 |
| POST | `/search` | JSONの`limit`（正の整数、省略時20）を受け取り、`maintenance:false`、`originLimit`、`requestByteLength`、`sha256`、`requestId`を返す |
| POST | `/echo` | JSON、元のバイト列の Base64、SHA-256。応答が64 KiBを超える場合は413 |
| GET | `/xml` `/text` `/html` | 固定のレスポンス。JSON以外を書き換えずに通す場合の確認に使用 |
| GET | `/auth/basic` | `demo:demo-pass`。不一致は 401 + `WWW-Authenticate` |
| GET | `/auth/bearer` | `interceptor-test-token`。不一致は 401 |
| GET | `/auth/credentials` | ダミーの`accessToken`と`tokenType`をJSONで返し、`Set-Cookie`も付ける |
| GET | `/auth/cookie` | `fixture_session=dummy-session-not-a-secret`が1つあれば200。それ以外は401 |
| GET | `/cookies` | ダミーの `fixture_session` Cookie (Secure; HttpOnly; SameSite=Lax) |
| GET | `/status/:code` | 200,201,202,204,400,401,403,404,409,418,422,429,500,502,503,504 |
| GET | `/redirect/:count` | 指定した回数（0〜5回）だけ同じホスト内でリダイレクト。0は直接JSONを返す |
| GET | `/delay?ms=` | 0..2000ms 待機 |
| GET | `/bytes?size=` | 指定したサイズのバイナリ（0〜65536バイト）。同じサイズなら毎回同じ内容 |
| GET | `/json/large?size=` | 指定したサイズのJSON（11〜65536バイト）。24KiBを超えるケースの確認用 |
| GET | `/malformed-json` | **意図的に不正な** JSON |

存在しないパスは404を返します。存在するパスに別のメソッドで送ると405を返します。全レスポンスに`Cache-Control: no-store`を付けます。
リクエスト・レスポンスとも最大64KiBです。リクエストが上限を超えると413を返します。
`x-fixture-request-id`は英数字と`._~-`の1〜64文字を受け付け、`/search`のレスポンスに含めます。
`requestByteLength`と`sha256`は、サーバーが実際に受け取ったバイト数とSHA-256です。

### GETで取得した認証情報を別APIで使う

`/auth/credentials`から取得したトークンは`/auth/bearer`で、Cookieは`/auth/cookie`で使えます。Cookieの属性は送らず、`fixture_session=...`の部分を送ります。
`fixture_session`の重複、不正な値、カンマ区切りのCookieは401です。Cookie名は大文字小文字を区別するため、`Fixture_Session`だけでは認証されません。Cookie認証の401には`WWW-Authenticate`を付けません。
ここで確認できるのはサーバー側の動作です。プラグインから別APIへ送信する機能は未実装です。

```sh
curl -si 127.0.0.1:8787/auth/credentials   # accessToken と Set-Cookie を取得
curl -s -H 'Authorization: Bearer interceptor-test-token' 127.0.0.1:8787/auth/bearer
curl -s -H 'Cookie: fixture_session=dummy-session-not-a-secret' 127.0.0.1:8787/auth/cookie
```

## 実行

Bun 1.4.2を使用します。

```sh
bun install --frozen-lockfile --ignore-scripts
bun run test && bun run typecheck && bun run lint
bun run test:runtime   # ローカルのWorkers環境でHTTPの動作を確認
bun run dev   # http://127.0.0.1:8787
curl -s -X POST 127.0.0.1:8787/search -H 'Content-Type: application/json' -d '{"limit":5}'
curl -s -u demo:demo-pass 127.0.0.1:8787/auth/basic
bun run bundle   # wrangler deploy --dry-run --env test (デプロイしない)
```

`compatibility_date`は固定したWranglerのローカル実行環境に合わせて2026-10-08にしています。
`/search`はサーバーが受け取った内容を返します。これだけで4つのHookやVPNの動作を確認したことにはなりません。

## CI / デプロイの流用

- `.github/workflows/integration.yaml`: 依存関係のインストール、テスト、型チェック、lint、Workers環境でのHTTPテスト、デプロイ用バンドルの確認を実行します。
- `.github/workflows/deployment.yaml`: 手動のみ。`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` secrets が必要。
  `env.test` (`interceptor-traffic-fixture`, workers.dev) へのみデプロイします。
- デプロイは既定ブランチからの`workflow_dispatch`、または認証済みの環境で`wrangler deploy --env test`を実行します。

## 由来

[`qtmleap/devcontainers`の`examples/hono-workers`](https://github.com/qtmleap/devcontainers/tree/8aa0d608ecec684d00dc1281180bfc0f07fd4d2c/examples/hono-workers)を基にしています。
