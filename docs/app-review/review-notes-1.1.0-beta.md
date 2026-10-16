# Interceptor 1.1.0 TestFlight review notes

This is the synthetic-script preview, not the future live-traffic automation release. No App Store 1.1.0 submission or Apple approval is claimed.

## English build notes

Interceptor 1.1.0 (TestFlight beta) - What to Test

NEW: Plugins (Settings > Plugins)
Plugins are small JavaScript scripts you can add from a repository, read, edit and test. In this build they are for inspection and synthetic testing only. Nothing runs on import, no plugin sees your captured traffic, and there is no live capture, no host network access and no files API.

Trust model
- Repository: you enter the HTTPS address of a static JSON file. It is fetched without cookies, cache, credentials or redirects; invalid, expired or oversized data is rejected.
- Hash check: each plugin lists a SHA-256 hash, and the downloaded bytes are checked against it. This detects a mismatch with the listing. It does not prove who published the plugin.
- Optional Ed25519 signature: a new signing key is never trusted automatically. You can pin it only by entering its full fingerprint, obtained from the publisher by another route. A pinned repository that changes key or drops its signature is refused.
- Unsigned or unpinned repositories are shown as unverified. Tap Add Repository, then you must acknowledge a warning and choose Add Unverified.
- Imports are immutable and disabled. Saving an edit makes a separate local copy, marked as locally edited, with no inherited publisher trust.

Test runs
- Run Synthetic Test runs the script once in an embedded QuickJS engine against an editable synthetic request or response.
- Any action the script returns is only displayed, labelled "Not sent", and never delivered. If the script returns zero actions, that row need not appear.
- Each run uses a fresh engine with an 8 MiB VM allocator limit (not a process memory limit) and a cooperative 50 ms time budget the engine checks (not a hard wall-clock limit). No timers; Promise jobs are not run.

Quick test (built-in example; no account, certificate or VPN needed beyond the app's initial consent)
1. Open Settings > Plugins.
2. Tap Create Example Script, then select the new script.
3. Edit the source and tap Save.
4. Choose Request or Response, optionally edit the synthetic event and config, then tap Run Synthetic Test.
5. Check the validated result and, if any action is returned, the "Not sent" label. Try Cancel during a run.

Feedback we would like
- Clarity of the unverified warning, hash wording and fingerprint display.
- Persistence: save an edit, fully quit and reopen the app, and confirm the script and edit remain. Start Add Repository, cancel, and confirm nothing was added.
- Errors: invalid JSON in the event or config, a script that loops forever, and a script that returns an invalid result.
- Layout on iPhone and iPad, Light and Dark, English and Japanese.

Not in this build: running plugins on real traffic, automatic rewriting, and webhook delivery.

## Japanese build notes

Interceptor 1.1.0(TestFlightベータ)- テスト内容

新機能: プラグイン(設定 > プラグイン)
小さなJavaScriptを確認・編集・合成データでテストできます。インポート時の実行、ホストのネットワークやファイルAPI、ライブキャプチャはありません。キャプチャしたトラフィックも渡されません。

信頼
- SHA-256ハッシュで一覧との不一致を検出しますが、公開者は証明されません。
- Ed25519署名の鍵は自動では信頼されません。別経路で入手したフィンガープリント全体の入力でのみ固定できます。
- 署名なし・鍵未固定は「リポジトリを追加」後に警告を確認し「未確認のまま追加」を選びます。
- インポートは変更不可・無効です。保存するとローカル編集済みの別コピーになり、公開者の信頼は引き継がれません。

テスト実行
- 「合成データでテスト」は組み込みQuickJSで1回実行します。
- 返されたアクションは必ず「未送信」と表示され、送信されません。0件ならその行は不要です。
- VMアロケータ上限は8 MiB(プロセスのメモリ上限ではない)。50ミリ秒は協調的で、厳密な制限ではありません。

手順(組み込みサンプル。初回の同意以外にアカウント・証明書・VPNは不要)
1. 設定 > プラグインを開く。
2. 「サンプルスクリプトを作成」をタップし、できたスクリプトを選ぶ。
3. ソースを編集して「保存」をタップ。
4. リクエストかレスポンスを選び、「合成データでテスト」をタップ。
5. 結果と、アクションがあれば「未送信」を確認。実行中のキャンセルも試す。

確認したい点
- 警告・ハッシュ説明・フィンガープリントのわかりやすさ。
- アプリを完全終了して再起動後も編集が残ること。リポジトリ追加をキャンセルして何も追加されないこと。
- 不正なJSON、無限ループ、不正な結果。
- iPhone/iPad、ライト/ダーク、英語/日本語の表示。

未対応: 実トラフィックでの実行、自動書き換え、Webhook配信。

## Publication evidence

The app declares C617.1 for the catalog file metadata checks inside its own container. The build test requires the bundled QuickJS notice to match the pinned upstream MIT license. Native release and distribution evidence is recorded in `docs/automation/foundation-ledger.md` and the external release artifacts.

Current Apple review considerations: source is visible and locally editable; the VM has no host API bridge and receives synthetic data only. This preview does not add a hosted software catalog, universal links to individual scripts, publisher accounts/content-reporting services, or per-script age gating. Do not claim that those future publication requirements are implemented or that Apple has preapproved this interpretation of Guidelines 2.5.2/4.7. External beta distribution is subject to Apple review.
