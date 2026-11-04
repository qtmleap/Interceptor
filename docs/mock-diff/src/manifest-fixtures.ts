// Synthetic UI fixtures only. Match data is declared here, never inferred from repository URLs.
// Author/category values are synthetic; optional display metadata is supported by the native app and producer.
export const packageFixtures = {
  search: {category:'requests', name:'Search limit', author:'Example Team', version:'1.0.0', publishedAt:'2026-10-19T00:00:00Z', glyph:'search', source:'repo', files:['scripts/request.js','scripts/response.js'], matches:[
    {hosts:['example.com'],methods:['POST'],path:{kind:'exact',value:'/synthetic'},hooks:{request:{onEnter:'scripts/request.js'}}},
    {hosts:['example.com','api.example.com'],methods:['GET'],path:{kind:'exact',value:'/search'},hooks:{response:{onLeave:'scripts/response.js'}}},
  ], summary:['検索件数の上限を5に変更します。','Sets the search limit to 5.']},
  preview: {category:'responses', name:'Response preview', author:'Example Team', version:'1.0.0', glyph:'response', source:'repo', files:['scripts/response.js'], matches:[
    {hosts:['api.example.com'],methods:['GET'],path:{kind:'exact',value:'/preview'},hooks:{response:{onLeave:'scripts/response.js'}}},
  ], summary:['レスポンスのJSONを確認します。','Inspect the response JSON.']},
  local: {category:'local', name:'Local example', author:'Local Author', version:'1.0.0', glyph:'local', source:'local', files:['scripts/request.js'], matches:[
    {hosts:['local.example.com'],methods:['POST'],path:{kind:'exact',value:'/local'},hooks:{request:{onEnter:'scripts/request.js'}}},
  ], summary:['ファイルから追加したサンプル','An example added from a file']},
} as const;
export type PackageID = keyof typeof packageFixtures;
// Category fixture values remain synthetic; the original unsupported-wire proposal is superseded.
// Catalog revision counters below are mock state, not manifest/Index fields.
export const categoryFixtures = {
  requests: {name:['リクエスト','Requests'], glyph:'search', page:'category-requests'},
  responses: {name:['レスポンス','Responses'], glyph:'response', page:'category-responses'},
  local: {name:['ローカル','Local'], glyph:'local', page:'manifests'},
} as const;
export type CategoryID = keyof typeof categoryFixtures;
// Metadata-only: once demo.catalogRev reaches `rev` the catalog advertises `version`. Refresh never changes installed versions or enabled state.
export const catalogUpdates = {search:{rev:13, version:'2.0.0', publishedAt:'2026-10-20T00:00:00Z'}} as const;
// Static publisher-declared release dates. Preview and Local intentionally have no date.
export const publicationDates: Partial<Record<PackageID, Record<string,string>>> = {
  search: {[packageFixtures.search.version]:packageFixtures.search.publishedAt, [catalogUpdates.search.version]:catalogUpdates.search.publishedAt},
};
export const catalogRevisions = {initial:12, refreshed:13} as const;
