import { defineConfig } from 'vitepress';

export default defineConfig({
    lang: 'ja-JP',
    title: 'Interceptor Plugins',
    description: 'InterceptorのPluginプレビュー向け作成ガイド。Manifest、JavaScript、合成テスト、署名付きリポジトリの配布。',
    themeConfig: {
        siteTitle: 'Interceptor Plugins（Preview）',
        nav: [
            { text: 'はじめに', link: '/guide/getting-started' },
            { text: '仕様', link: '/reference/manifest' },
            { text: 'サンプル', link: '/examples' },
        ],
        sidebar: [
            {
                text: 'プラグインを書く',
                items: [
                    { text: '概要と実装状況', link: '/' },
                    { text: 'はじめてのプラグイン', link: '/guide/getting-started' },
                    { text: '権限とデータの共有', link: '/guide/permissions' },
                    { text: '配布と更新', link: '/guide/distribution' },
                ],
            },
            {
                text: 'リファレンス',
                items: [
                    { text: 'Manifest', link: '/reference/manifest' },
                    {
                        text: 'JavaScript API',
                        link: '/reference/javascript',
                        items: [
                            { text: 'onRequest', link: '/reference/javascript#onrequest' },
                            { text: 'onResponse', link: '/reference/javascript#onresponse' },
                            { text: '実行タイミング', link: '/reference/javascript#future-hooks' },
                        ],
                    },
                    { text: 'Webhook', link: '/reference/webhook' },
                ],
            },
            {
                text: '試す・調べる',
                items: [
                    { text: 'サンプル', link: '/examples' },
                    { text: 'トラブルシューティング', link: '/troubleshooting' },
                ],
            },
        ],
        search: {
            provider: 'local',
            options: {
                locales: {
                    root: {
                        translations: {
                            button: { buttonText: '検索', buttonAriaLabel: 'ドキュメントを検索' },
                            modal: {
                                displayDetails: '詳細を表示',
                                resetButtonTitle: '検索条件をクリア',
                                backButtonTitle: '検索を閉じる',
                                noResultsText: '見つかりませんでした',
                                footer: { selectText: '選択', navigateText: '移動', closeText: '閉じる' },
                            },
                        },
                    },
                },
            },
        },
        outline: { label: 'このページの内容', level: [2, 3] },
        docFooter: { prev: '前のページ', next: '次のページ' },
        sidebarMenuLabel: 'メニュー',
        returnToTopLabel: 'ページ上部へ',
        darkModeSwitchLabel: '表示テーマ',
        lightModeSwitchTitle: 'ライトモードに切り替え',
        darkModeSwitchTitle: 'ダークモードに切り替え',
        skipToContentLabel: '本文へスキップ',
        footer: { message: '開発中のPluginプレビュー向け資料です。合成テストでは外部へ送信しません。' },
    },
});
