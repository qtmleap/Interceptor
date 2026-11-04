import {createQueueModel} from './install-queue-model';
import {installQueueClient} from './install-queue-ui';
import {referenceCss, queueCss} from './sileo-reference-style';
import {packageFixtures, categoryFixtures, catalogUpdates, catalogRevisions, publicationDates, type PackageID, type CategoryID} from './manifest-fixtures';
import {row, section, badge, escape, css} from './components';

export type Lang = 'ja'|'en';
export type Tab = 'Sources'|'Packages'|'Scripts'|'Search';
export type Kind = 'ok'|'warn'|'error'|'neutral';
export type Glyph = 'source'|'package'|'script'|'search'|'response'|'local'|'plus'|'close'|'trash';
const paths: Record<Glyph,string> = {
  source:'M3 6h7l2 3h9v12H3z M3 6V3h8l2 3',
  package:'m12 2 9 5v10l-9 5-9-5V7z M3 7l9 5 9-5 M12 12v10',
  script:'M6 2h8l5 5v15H6z M14 2v6h5 M10 12l-2 2 2 2 M15 12l2 2-2 2',
  search:'M20 20l-5-5 M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0',
  response:'M4 6h12a4 4 0 0 1 0 8H5 M9 10l-4 4 4 4',
  local:'M3 7h7l2 3h9v11H3z M3 7V4h8l2 3',
  plus:'M12 4v16 M4 12h16',
  close:'m6 6 12 12 M18 6 6 18',
  trash:'M3 6h18 M9 6V3h6v3 M6 6l1 15h10l1-15 M10 10v7 M14 10v7',
};
export const svg = (name: Glyph) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name].split(' M').map((p,i)=>`<path d="${i?'M':''}${p}"/>`).join('')}</svg>`;
export const tile = (name: Glyph, large = false) => `<span class="tile ${name} ${large?'large':''}">${svg(name)}</span>`;
export const href = (name: string, lang: Lang) => `manifest-browser-${name}${lang==='en'?'-en':''}.html`;
const link = (name: string, label: string, lang: Lang, className = '', attrs = '') => `<a class="${className}" ${attrs} href="${href(name,lang)}">${escape(label)}</a>`;
export const extraCss = `
.mf{--bg:#fff;--surface:#f5f5f7;--accent:#007e87;--buttonInk:#fff;--muted:#66676c;background:var(--bg)}
.mf a{color:inherit;text-decoration:none}.mf button,.mf input{font:inherit}.mf a:focus-visible,.mf button:focus-visible,.mf input:focus-visible{outline:3px solid var(--accent);outline-offset:3px}
.mf .detail{margin-left:0}.mf header{height:88px;border:0;background:var(--bg)}.mf header .status{height:38px;padding-top:10px}.mf .bar{display:flex;height:50px;padding:0 20px;justify-content:space-between}.mf .bar strong{font-size:17px}.mf .back,.mf .action{color:var(--accent);font-size:17px;min-width:44px;min-height:44px;display:flex;align-items:center}.mf .action{justify-content:flex-end}.mf .source-controls{display:flex;gap:16px}.mf .action svg{width:24px;height:24px}.mf .bar .spacer{min-width:44px}
.mf main{padding:0 20px 100px;max-width:820px}.mf .large-title{font-size:34px;line-height:1.12;letter-spacing:-.8px;margin:10px 0 24px;font-weight:750;overflow-wrap:anywhere}.mf section{margin-top:24px}.mf h2{font-size:18px;font-weight:700;color:var(--ink);text-transform:none;padding:0;margin-bottom:12px}.mf .group{border-radius:12px}.mf .row{padding:12px 16px}.mf .footer{margin:8px 2px 0}.mf .catalog{background:none;border-radius:0}.mf .catalog .row{padding:14px 0;align-items:center;gap:12px;min-height:82px}.mf .catalog .row+.row:before{left:62px}.mf .catalog .label strong{font-size:17px;font-weight:650}.mf .catalog .sub{font-size:13px;line-height:1.35}.mf .state{font-size:12px;color:var(--muted);margin-top:5px;display:block}.mf .chevron{font-size:22px}
.mf .tile{display:flex;width:50px;height:50px;border-radius:12px;align-items:center;justify-content:center;flex:none;color:white;background:#279caa}.mf .tile svg{width:29px;height:29px}.mf .tile.large{width:72px;height:72px;border-radius:17px}.mf .tile.large svg{width:42px;height:42px}.mf .tile.package,.mf .tile.search{background:#358bac}.mf .tile.response{background:#8b72b1}.mf .tile.local,.mf .tile.script{background:#707d90}
.mf .package-hero{display:flex;align-items:center;gap:16px;margin:16px 0 24px}.mf .hero-copy{flex:1;min-width:0}.mf .hero-copy h1{font-size:24px;line-height:1.14;margin:0 0 6px;letter-spacing:-.4px;overflow-wrap:anywhere}.mf .hero-copy p{font-size:14px;line-height:1.4;margin:0;color:var(--muted)}.mf .hero-action{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin:16px 0}.mf .pill{display:inline-flex;align-items:center;justify-content:center;min-height:36px;padding:7px 20px;border:0;border-radius:22px;background:var(--accent);color:var(--buttonInk);font-size:15px;font-weight:700}.mf .pill.destructive{background:transparent;color:var(--error);box-shadow:inset 0 0 0 1px var(--line)}.mf .pill.disabled{opacity:.4;pointer-events:none}.mf .text-link{color:var(--accent);font-weight:550;min-height:44px;display:inline-flex;align-items:center}.mf .primary{margin:20px 0 0;min-height:46px;border:0;border-radius:12px;background:var(--accent);color:var(--buttonInk);font:600 17px var(--ui-font);width:100%}.mf .primary:disabled{opacity:.4}
.mf dialog.dialog{padding:0;border:0;color:var(--ink)}.mf dialog.dialog:not([open]){display:none}.mf dialog.dialog::backdrop{background:#0006}.mf .catalog>.row:nth-child(1 of .row:not([hidden])):before{display:none}.mf .search-box{display:flex;gap:8px;align-items:center;border-radius:11px;background:var(--surface);padding:0 12px;min-height:44px;margin:16px 0 10px}.mf .search-box svg{width:19px;height:19px;color:var(--muted);flex:none}.mf .search-box input{border:0;outline:0;background:transparent;min-width:0;width:100%;height:44px;color:var(--ink);font-size:16px}.mf .search-box button{background:none;border:0;color:var(--accent);font-size:14px;min-height:44px;flex:none}.mf .result-count{font-size:13px;color:var(--muted);margin:10px 0 0}.mf [hidden]{display:none!important}.mf .empty{padding:32px 16px;text-align:center;color:var(--muted)}.mf .empty svg{width:30px;height:30px;margin-bottom:12px}.mf .empty strong{display:block;font-size:18px;color:var(--ink);margin-bottom:8px}.mf .repo-url{font-size:13px;color:var(--muted);overflow-wrap:anywhere}.mf .field{background:var(--surface);border-radius:12px;padding:14px;width:100%;border:1px solid var(--line);color:var(--ink)}.mf .field-label{font-size:14px;display:block;margin:20px 0 8px}
.mf .tabbar{height:78px;padding:9px 12px 22px;gap:8px;background:var(--bg)}.mf .tabbar a{display:flex;flex:1;flex-direction:column;align-items:center;gap:4px;font-size:11px;color:var(--muted)}.mf .tabbar svg{width:24px;height:24px}.mf .tabbar a.active{color:var(--accent)}.mf .sidebar{display:none}.mf pre.code{margin:0;padding:16px;font:13px/1.6 ui-monospace,Menlo,monospace;white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word}.mf.full main{padding-bottom:32px}.mf .dialog-backdrop{position:fixed;inset:0;z-index:9;background:#0006;display:grid;place-items:center}.mf .dialog{width:290px;border-radius:14px;background:var(--surface);text-align:center;overflow:hidden}.mf .dialog h3{font-size:17px;line-height:1.4;margin:20px 18px}.mf .dialog-actions{display:flex;border-top:.5px solid var(--line)}.mf .dialog-actions a{min-height:46px;flex:1;color:var(--accent);display:grid;place-items:center}.mf .dialog-actions a+a{border-left:.5px solid var(--line);font-weight:600}.mf .dialog-backdrop.inline{position:static;background:none;padding:16px}
@media(prefers-color-scheme:dark){.mf{--bg:#151517;--surface:#242427;--ink:#f7f7f8;--muted:#a1a1a9;--line:#37373c;--accent:#74d1d6;--buttonInk:#123336}.mf .tile{filter:brightness(.9)}}
@media(min-width:700px){.mf .sidebar{display:block;width:248px;position:fixed;inset:0 auto 0 0;padding:32px 16px;background:var(--surface);border-right:.5px solid var(--line)}.mf .sidebar .sidebar-title{text-align:left;font-size:28px;margin:30px 12px}.mf .sidebar a{display:flex;align-items:center;gap:12px;padding:13px 14px;margin:4px 0;border-radius:10px;font-weight:550}.mf .sidebar svg{width:22px;height:22px}.mf .sidebar .active{background:var(--accent);color:var(--buttonInk)}.mf .detail{margin-left:248px}.mf main{padding:0 30px 48px}.mf .bar{padding:0 30px}.mf .tabbar{display:none}.mf .large-title{margin-top:12px}.mf.full .detail{margin-left:0}.mf.full main{max-width:1000px}.mf.full .sidebar{display:none}}
`;
export const statusRow = (kind: Kind,label:string) => `<div class="row"><div class="label">${badge(kind,label)}</div></div>`;
export const checkStates = ['unknown','checking','success','update','failed','catalogUpdate'] as const;
export const checkRow = (state: typeof checkStates[number],lang: Lang) => {
 const values={unknown:['未確認','Not checked'],checking:['取得中…','Loading…'],success:['更新なし','No updates'],update:['更新あり','Update available'],failed:['取得できませんでした','Could not load'],catalogUpdate:['一覧に更新があります','Catalog update available']} as const;
 return statusRow(state==='failed'?'error':state==='update'||state==='catalogUpdate'?'warn':state==='success'?'ok':'neutral',values[state][lang==='ja'?0:1]);
};
export const stateRow = (state: 'trusted'|'enabled'|'disabled',lang:Lang) => statusRow(state==='disabled'?'neutral':'ok',({trusted:['公開元の鍵を確認済み','Publisher key verified'],enabled:['有効','Enabled'],disabled:['追加済み・無効','Added · Disabled']} as const)[state][lang==='ja'?0:1]);
export const primaryButton = (label:string,destination:string,lang:Lang,disabled=false) => disabled?`<button class="primary" disabled>${escape(label)}</button>`:link(destination,label,lang,'primary pill');
export const pill = (label:string,destination:string,lang:Lang,tone='') => `<a class="pill ${tone}" href="${href(destination,lang)}?apply=1${tone==='add'?'&add=1':''}">${escape(label)}</a>`;
export const codeBlock = (value:string) => `<pre class="code" tabindex="0">${escape(value)}</pre>`;
export const navRow = (label:string,destination:string,lang:Lang,value='') => `<a href="${href(destination,lang)}" class="row"><span class="label">${escape(label)}</span><span class="value">${escape(value)}</span><span class="chevron">›</span></a>`;
export const iconRow = (name:string,purpose:string,state:string,destination:string,lang:Lang,glyph:Glyph='package',searchable=true) => `<a class="row" href="${href(destination,lang)}" ${searchable?`data-catalog-item data-package="${name==='Search limit'?'search':name==='Response preview'?'preview':'local'}" data-search="${escape(`${name} ${purpose}`.toLowerCase())}"`:''}>${tile(glyph)}<span class="label"><strong>${escape(name)}</strong><span class="sub">${escape(purpose)}</span>${state?`<span class="state">${escape(state)}</span>`:''}</span><span class="chevron">›</span></a>`;
export const scriptRow = (name:string,path:string,lang:Lang,owner:PackageID='search') => iconRow(name,path,'',owner==='local'?'source-local':owner==='preview'?'source-preview':name==='response.js'?'source-response':'source-request',lang,'script',false);
export const scriptDirectoryRow = (name:string,destination:string,lang:Lang) => iconRow(name,'','',destination,lang,'source',false);
export const scriptPackageRow = (owner:PackageID,lang:Lang) => iconRow(packageFixtures[owner].name,packageFixtures[owner].author+' · 1.0.0','', 'script-package-'+owner,lang,packageFixtures[owner].glyph,false);
export const scriptMatches = (owner:PackageID,file:string,lang:Lang) => {
 const matches=packageFixtures[owner].matches.flatMap(match=>Object.entries(match.hooks).flatMap(([direction,hooks])=>Object.entries(hooks).filter(([,script])=>script===file).map(([hook])=>({match,hook:direction+'.'+hook}))));
 if(!matches.length)throw new Error(`No manifest binding for ${owner}/${file}`);
 return matches.map(({match,hook},index)=>section((lang==='ja'?'実行条件':'Matching traffic')+(matches.length>1?' '+(index+1):''),row(lang==='ja'?'対象ホスト':'Target hosts',match.hosts.join(', '))+row(lang==='ja'?'メソッド':'Method',match.methods.join(', '))+row(lang==='ja'?'パス':'Path',match.path.value)+row('Hook',hook))).join('');
};
export const packageHero = (name:string,purpose:string,action:string,glyph:Glyph='package',lang:Lang='ja') => {
 if(glyph==='source')return `<div class="package-hero">${tile(glyph,true)}<div class="hero-copy"><h1>${escape(name)}</h1><p>${escape(purpose)}</p></div></div>`;
 const entry=Object.entries(packageFixtures).find(([,fixture])=>fixture.name===name);
 if(!entry)throw new Error(`No declared match fixture for ${name}`);
 const [id,fixture]=entry;
 const hosts=[...new Set(fixture.matches.flatMap(match=>match.hosts))];
 return `<div class="package-banner"><div class="package-profile" data-detail-owner="${id}">${tile(glyph,true)}<div class="profile-copy"><h1>${escape(name)}</h1><div class="target-summary"><div class="host-line"><span>${lang==='ja'?'対象ホスト':'Target hosts'}</span>${hosts.map(host=>`<strong>${escape(host)}</strong>`).join('')}</div></div></div></div><div class="profile-actions">${action}</div></div>`;
};
// Shared hero stays visible while these mutually exclusive panels change.
export const packagePanels = (id:PackageID,lang:Lang,details:string,version:string) => `<div data-package-panels><div class="detail-tabs" role="tablist" aria-label="${lang==='ja'?'Packageの詳細':'Package details'}"><button type="button" role="tab" id="package-details-tab" aria-controls="package-details-panel" aria-selected="true" class="active" data-package-tab="details">${lang==='ja'?'詳細':'Details'}</button><button type="button" role="tab" id="package-version-tab" aria-controls="package-version-panel" aria-selected="false" tabindex="-1" data-package-tab="version">${lang==='ja'?'バージョン':'Version'}</button></div><div id="package-details-panel" role="tabpanel" aria-labelledby="package-details-tab" data-package-panel="details"><p class="package-purpose">${escape(packageFixtures[id].summary[lang==='ja'?0:1])}</p>${details}</div><div id="package-version-panel" role="tabpanel" aria-labelledby="package-version-tab" data-package-panel="version" hidden>${version}</div></div>`;
export const repoRow = (name:string,subtitle:string,count:string,page:string,lang:Lang,glyph:Glyph='source',countKey='',repo=false) => `<a class="row repo-row" href="${href(page,lang)}" ${repo?'data-source-row':''}>${tile(glyph)}<span class="label"><strong>${escape(name)}</strong><span class="sub">${escape(subtitle)}</span></span><span class="trailing-count" ${countKey?`data-count="${countKey}"`:''}>${escape(count)}</span><span class="chevron">›</span></a>`;
export const packageRow = (id:PackageID,lang:Lang,installed=false,from='') => {
 const f=packageFixtures[id],title=escape(f.name),summary=escape(f.summary[lang==='ja'?0:1]),search=escape(`${f.name} ${f.author} ${f.summary.join(' ')}`.toLowerCase());
 const row=`<a class="row package-row" draggable="false" data-package-link data-package="${id}" ${from?`data-from="${from}"`:''} href="${href(id==='search'?'manifest-import':id==='preview'?'manifest-preview':'manifest-local',lang)}"><span class="package-icon">${tile(f.glyph)}<span class="install-badge" aria-label="${lang==='ja'?'インストール済み':'Installed'}" hidden>✓</span></span><span class="label"><strong>${title}</strong><span class="package-meta" data-package-meta>${escape(f.author+' · '+f.version)}</span><span class="sub">${summary}</span></span><span class="chevron">›</span></a>`;
 if(!installed)return row.replace('data-package-link',`data-package-link data-catalog-item data-search="${search}"`);
 const confirmation=id==='search'?'manifest-delete-confirm':id==='preview'?'manifest-preview-delete-confirm':'manifest-local-delete-confirm';
 return `<div class="swipe-wrap" data-package-template="${id}" data-catalog-item data-search="${search}"><div class="swipe-track">${row}<a class="swipe-action" href="${href(confirmation,lang)}" tabindex="-1" aria-label="${lang==='ja'?'削除':'Delete'} ${title}">${svg('trash')}<span>${lang==='ja'?'削除':'Delete'}</span></a></div></div>`;
};
export const managePill = (id:PackageID,lang:Lang) => {
 const name=packageFixtures[id].name,confirm=id==='search'?'manifest-delete-confirm':id==='preview'?'manifest-preview-delete-confirm':'manifest-local-delete-confirm';
 return `<button type="button" class="pill" data-open-management="${id}" aria-haspopup="dialog">${lang==='ja'?'管理':'Modify'}</button><dialog class="action-sheet" data-management="${id}" aria-label="${escape(name)}"><span class="sr-only" tabindex="-1" autofocus>${escape(name)}</span><div class="sheet-options"><button type="button" data-reinstall="${id}">${lang==='ja'?'再インストール':'Reinstall'}</button><a class="sheet-delete" href="${href(confirm,lang)}">${lang==='ja'?'削除':'Uninstall'}</a></div><button type="button" class="sheet-cancel" data-close>${lang==='ja'?'キャンセル':'Cancel'}</button></dialog>`;
};
export const queueBar = (lang:Lang,preview=false) => `<button type="button" class="queue-tray ${preview?'queue-preview':''}" ${preview?'data-queue-open':'data-queue-tray hidden'}><span>${lang==='ja'?'キュー':'Queued'}<strong ${preview?'':'data-queue-count'}>${preview?(lang==='ja'?'2件':'2 Packages'):''}</strong></span><svg viewBox="0 0 24 14" aria-hidden="true"><path d="m3 11 9-8 9 8"/></svg></button>`;
export const installSheet = (lang:Lang) => `<dialog class="install-sheet" data-install-sheet aria-labelledby="install-sheet-title"><button type="button" class="sheet-dismiss" data-queue-close aria-label="${lang==='ja'?'閉じる':'Close'}"><svg viewBox="0 0 36 16" aria-hidden="true"><path d="m4 4 14 8 14-8"/></svg></button><h2 id="install-sheet-title" tabindex="-1" autofocus>${lang==='ja'?'インストール':'Install'}</h2><div class="queue-items" data-queue-items></div><p class="queue-status" role="status" aria-live="polite" data-queue-status></p><div class="queue-footer"><button type="button" class="queue-confirm" data-queue-confirm>${lang==='ja'?'インストール':'Confirm'}</button><button type="button" class="queue-clear" data-queue-clear>${lang==='ja'?'キューを消去':'Clear Queue'}</button></div></dialog>`;
export const activationRow = (id:PackageID,lang:Lang) => `<a class="row togglink" data-activation-owner="${id}" href="${href('manifest-confirm',lang)}" role="switch" aria-checked="false"><span class="label">${lang==='ja'?'有効':'Enabled'}</span><span class="toggle" aria-hidden="true"></span></a>`;
export const deleteConfirmation = (id:PackageID,lang:Lang) => `<dialog class="dialog" data-auto aria-label="${lang==='ja'?'削除の確認':'Confirm deletion'}"><h3>${escape(packageFixtures[id].name)}${lang==='ja'?'を削除しますか？':' — Delete this Package?'}</h3><div class="dialog-actions"><a data-cancel data-return-owner="${id}" autofocus href="${href('packages',lang)}">${lang==='ja'?'キャンセル':'Cancel'}</a><a class="error" href="${href('packages',lang)}?remove=${id}">${lang==='ja'?'削除':'Delete'}</a></div></dialog>`;
const formatPublisherDate = (value:string,lang:Lang) => new Intl.DateTimeFormat(lang==='ja'?'ja-JP':'en-US',{calendar:'gregory',timeZone:'UTC',year:'numeric',month:lang==='ja'?'long':'short',day:'numeric'}).format(new Date(value));
export const versionRows = (lang:Lang,version:string,publishedAt?:string) => `<div class="row"><div class="label" data-detail-version>${escape(version)}</div>${publishedAt?`<div class="value" data-detail-published-at>${escape(formatPublisherDate(publishedAt,lang))}</div>`:''}</div>`;
export const confirmation = (title:string,ok:string,cancel:string,lang:Lang,confirmDestination='manifest',inline=false,cancelDestination='manifest-added') => {
 const contents=`<h3>${escape(title)}</h3><div class="dialog-actions"><a data-cancel autofocus href="${href(cancelDestination,lang)}">${escape(cancel)}</a><a href="${href(confirmDestination,lang)}?apply=1">${escape(ok)}</a></div>`;
 return inline?`<div class="dialog-backdrop inline"><div class="dialog">${contents}</div></div>`:`<dialog class="dialog" data-auto aria-label="${escape(title)}">${contents}</dialog>`;
};
export const searchField = (lang:Lang,query='',scope:'repository'|'category'|'packages'|'all'|'global'='category') => {
 const ja=lang==='ja',label=({repository:['このリポジトリ内を検索','Search this repository'],category:['このカテゴリ内を検索','Search this category'],packages:['パッケージを検索','Search for Packages'],all:['Packageを検索','Search all Packages'],global:['パッケージを検索','Search for Packages']} as const)[scope][ja?0:1];
 const field=`<div class="search-box" data-search-scope="${scope}">${svg('search')}<input type="search" aria-label="${label}" placeholder="${label}" value="${escape(query)}"><button type="button" data-clear>${ja?'クリア':'Clear'}</button></div>`;
 return scope==='global'?field:field+`<p class="result-count" aria-live="polite" data-result-count></p><div class="empty" data-no-results hidden>${svg('search')}<strong>${ja?'一致するPackageはありません':'No matching Packages'}</strong><p data-empty-help hidden></p></div>`;
};
export const sortControl = (lang:Lang) => `<div class="sort-row"><select class="sort-select" data-sort aria-label="${lang==='ja'?'並べ替え':'Sort Packages'}"><option value="asc">${lang==='ja'?'名前 ↑':'Name ↑'}</option><option value="desc">${lang==='ja'?'名前 ↓':'Name ↓'}</option></select></div>`;
// Synthetic category rows use supported optional display metadata. Count is Packages in the category.
export const categoryRow = (id:CategoryID,count:string,lang:Lang) => `<a class="row repo-row category-row" href="${href(categoryFixtures[id].page,lang)}" data-category-link="${id}">${tile(categoryFixtures[id].glyph)}<span class="label"><strong>${escape(categoryFixtures[id].name[lang==='ja'?0:1])}</strong></span><span class="trailing-count" data-count="category-${id}">${escape(count)}</span><span class="chevron">›</span></a>`;
// Refresh feedback. Idle shows nothing (the Refresh button is screen-reader/focus-visible only). Pull gesture and button share one page handler.
export const refreshStates = ['idle','refreshing','error'] as const;
export const refreshControl = (state:typeof refreshStates[number],lang:Lang) => {
 const ja=lang==='ja',copy={idle:'',refreshing:ja?'リポジトリを更新中…':'Refreshing sources…',error:ja?'更新できませんでした。':'Couldn’t refresh.'}[state];
 const label=state==='error'?(ja?'再試行':'Try Again'):(ja?'リポジトリを更新':'Refresh sources');
 return `<div class="refresh" data-refresh data-state="${state}"><div class="pull-indicator" aria-hidden="true"><span class="spinner"></span><span data-pull-text></span></div><div class="refresh-row"><span class="spinner row-spinner" aria-hidden="true"></span><span class="refresh-text" data-refresh-text aria-hidden="true">${escape(copy)}</span><button type="button" class="refresh-button" data-refresh-button aria-disabled="${state==='refreshing'}" aria-busy="${state==='refreshing'}">${escape(label)}</button></div><p class="sr-only" role="status" aria-live="polite" data-refresh-announce>${escape(copy)}</p></div>`;
};
// Hidden unless the installed version differs from the catalog version (page script toggles it).
export const updatePill = (id:PackageID,lang:Lang) => `<a class="pill add" data-update-cta="${id}" hidden href="${href('manifest-updated',lang)}?apply=1&add=1">${lang==='ja'?'更新':'Update'}</a>`;
const searchScript = `<script>
const en = document.documentElement.lang === 'en';
const route = location.pathname.split('/').pop().replace('manifest-browser-', '').replace(/(-en)?\\.html$/, '');
const destination = name => 'manifest-browser-' + name + (en ? '-en' : '') + '.html';
const parameters = new URLSearchParams(location.search);
const fixtures = ${JSON.stringify(packageFixtures)};
const catalogUpdates = ${JSON.stringify(catalogUpdates)};
const publicationDates = ${JSON.stringify(publicationDates)};
const formatPublisherDate = ${formatPublisherDate.toString()};
const categories = ${JSON.stringify(categoryFixtures)};
const saved = (() => { try { const value=JSON.parse(parameters.get('demo') || '{}'); return value && !Array.isArray(value) && typeof value==='object' ? value : {}; } catch { return {}; } })();
const normalize = (key, value) => Object.hasOwn(fixtures,key) && value && typeof value==='object' && !('version' in value) && 'added' in value ? {version:value.active||value.added,enabled:!!value.active} : value;
const migrated = Object.fromEntries(Object.entries(saved).map(([key,value])=>[key,normalize(key,value)]));
const demo = {local:{version:'1.0.0',enabled:false}, ...migrated};
demo.catalogRev = Number.isFinite(demo.catalogRev) ? demo.catalogRev : ${catalogRevisions.initial};
const queueModel = (${createQueueModel.toString()})(${JSON.stringify(Object.fromEntries(Object.entries(packageFixtures).map(([id,f])=>[id,[f.version,...(catalogUpdates[id as keyof typeof catalogUpdates]?[catalogUpdates[id as keyof typeof catalogUpdates].version]:[])]])))});
demo.queue=queueModel.normalize(demo.queue);
if(!parameters.has('demo')&&['manifest-install-queue','manifest-install-queue-error','components'].includes(route))demo.queue=[{id:'search',version:'1.0.0',kind:'add'},{id:'preview',version:'1.0.0',kind:'add'}];
if(!parameters.has('demo')&&route==='manifest-manage')demo.search={version:'1.0.0',enabled:false};

if(['sources-refreshed','manifest-update'].includes(route))demo.catalogRev = Math.max(demo.catalogRev,${catalogRevisions.refreshed});
const catalogVersion = id => { const update=catalogUpdates[id]; return update && demo.catalogRev>=update.rev ? update.version : fixtures[id].version; };
const removed = parameters.get('remove');
if(removed && Object.hasOwn(fixtures,removed))demo[removed]=null;
if(parameters.get('removeSource')==='repo')demo.sourceHidden=true;
if(parameters.get('addSource')==='repo')demo.sourceHidden=false;
const states = {'packages-added':['search','1.0.0',false],'manifest-update':['search','1.0.0',true],'manifest-added':['search','1.0.0',false],manifest:['search','1.0.0',true],'manifest-enable':['search','2.0.0',true],'manifest-replace-confirm':['search','2.0.0',true],'manifest-updated':['search','2.0.0',true],'manifest-disabled-update':['search','2.0.0',false],'manifest-preview-added':['preview','1.0.0',false],'manifest-preview-enabled':['preview','1.0.0',true],'manifest-local':['local','1.0.0',false],'manifest-local-enabled':['local','1.0.0',true]};
if(states[route]){const [id,version,enabled]=states[route];const apply=parameters.get('apply')==='1',add=parameters.get('add')==='1',current=demo[id];if(removed!==id){if(!parameters.has('demo'))demo[id]={version,enabled};else if(apply){if(!current){/* Legacy Add URLs never install; only the sheet Confirm commits. */}else if(add){if(route==='manifest-updated'&&catalogUpdates[id]&&current.version===fixtures[id].version&&catalogVersion(id)===catalogUpdates[id].version)demo[id]={version:catalogVersion(id),enabled:current.enabled};}else demo[id]={version:current.version,enabled};}}}
const target=(id,state)=>id==='search'?(!state?'manifest-import':state.version==='2.0.0'?(state.enabled?'manifest-updated':'manifest-disabled-update'):state.enabled?'manifest':'manifest-added'):id==='preview'?(!state?'manifest-preview':state.enabled?'manifest-preview-enabled':'manifest-preview-added'):state?(state.enabled?'manifest-local-enabled':'manifest-local'):'manifests';
const renderCatalog = () => {
 document.querySelectorAll('[data-package-link]').forEach(item=>{const id=item.dataset.package,state=demo[id];item.href=destination(target(id,state));const installedList=!!item.closest('[data-package-template]');item.querySelector('[data-package-meta]').textContent=fixtures[id].author+' · '+(installedList&&state?state.version:catalogVersion(id));item.querySelector('.install-badge').hidden=!state;const wrapper=item.closest('[data-package-template]');if(wrapper)wrapper.querySelector('.swipe-action').hidden=!state;});
 document.querySelectorAll('[data-version-owner]').forEach(owner=>{const id=owner.dataset.versionOwner,state=demo[id],version=state?state.version:catalogVersion(id),value=owner.querySelector('[data-detail-version]'),date=owner.querySelector('[data-detail-published-at]'),publishedAt=publicationDates[id]?.[version];if(value)value.textContent=version;if(date){date.hidden=!publishedAt;date.textContent=publishedAt?formatPublisherDate(publishedAt,en?'en':'ja'):'';}});

 document.querySelectorAll('[data-catalog-rev]').forEach(item=>{item.textContent=String(demo.catalogRev);});
 document.querySelectorAll('[data-install-cta]').forEach(item=>{item.hidden=!!demo[item.dataset.installCta];});
 document.querySelectorAll('[data-update-cta]').forEach(item=>{const id=item.dataset.updateCta,state=demo[id];item.hidden=!!demo.sourceHidden||!(state&&catalogUpdates[id]&&state.version===fixtures[id].version&&catalogVersion(id)===catalogUpdates[id].version);const row=item.closest('[data-version-update-row]');if(row)row.hidden=item.hidden;});
};
renderCatalog();
document.querySelectorAll('[data-script-owner]').forEach(group=>{group.hidden=!demo[group.dataset.scriptOwner];});
document.querySelectorAll('[data-source-row]').forEach(row=>{row.hidden=!!demo.sourceHidden;});
const installed=id=>!!demo[id];
const counts={all:(demo.sourceHidden?0:2)+(demo.local?1:0),local:demo.local?1:0,repo:2,'category-requests':1,'category-responses':1,installed: ['search','preview'].filter(installed).length,sources:demo.sourceHidden?0:1};
document.querySelectorAll('[data-count]').forEach(label=>{label.textContent=String(counts[label.dataset.count]);});
document.querySelectorAll('[data-activation-section]').forEach(item=>{item.hidden=!demo[item.dataset.activationSection];});
document.querySelectorAll('[data-activation-owner]').forEach(item=>{const id=item.dataset.activationOwner,state=demo[id];item.hidden=!state;if(!state)return;item.setAttribute('aria-checked',String(!!state.enabled));const page=state.enabled?(id==='search'?(state.version==='2.0.0'?'manifest-disabled-update':'manifest-added'):id==='preview'?'manifest-preview-added':'manifest-local'):(id==='search'?(state.version==='2.0.0'?'manifest-disabled-confirm':'manifest-confirm'):id==='preview'?'manifest-preview-confirm':'manifest-local-confirm');item.href=destination(page)+(state.enabled?'?apply=1':'');});
document.querySelectorAll('[data-return-owner]').forEach(item=>{const id=item.dataset.returnOwner;item.href=destination(target(id,demo[id]));});
document.querySelectorAll('a[href]').forEach(anchor=>{const file=anchor.getAttribute('href').split('/').pop().split('?')[0];if(file===destination('manifest')&&!anchor.search.includes('apply=1'))anchor.href=destination(target('search',demo.search));});
const manifestJSON=document.querySelector('[data-manifest-json]');if(manifestJSON&&demo.search){const value=JSON.parse(manifestJSON.textContent);value.version=demo.search.version;const publishedAt=publicationDates.search?.[value.version];if(publishedAt)value.publishedAt=publishedAt;else delete value.publishedAt;manifestJSON.textContent=JSON.stringify(value,null,2);}
const items=[...document.querySelectorAll('[data-catalog-item]')];
const eligible=item=>{const id=item.dataset.packageTemplate||item.dataset.package;if(item.closest('[data-package-list],[data-search-results]'))return fixtures[id].source!=='local'&&(!demo.sourceHidden||installed(id));return item.hasAttribute('data-package-template')?installed(id):fixtures[id].source==='local'?installed(id):!demo.sourceHidden;};
const search=document.querySelector('input[type="search"]');
const globalSearch=!!document.querySelector('[data-search-scope=global]');
if(globalSearch&&search&&parameters.has('searchQuery'))search.value=parameters.get('searchQuery')||'';
if(globalSearch&&!parameters.has('demo')&&route==='search-no-source')demo.sourceHidden=true;
const update=()=>{const query=search?search.value.trim().toLowerCase():'';items.forEach(item=>{item.hidden=!eligible(item)||!item.dataset.search.includes(query)||(globalSearch&&!query);});const matches=items.filter(item=>!item.hidden).length;const count=document.querySelector('[data-result-count]');if(count){count.hidden=globalSearch||!query;count.textContent=en?matches+(matches===1?' Package':' Packages'):matches+'件';}const empty=document.querySelector('[data-no-results]');if(empty){empty.hidden=matches!==0;empty.querySelector('strong').textContent=query?(en?'No matching Packages':'一致するPackageはありません'):(en?'No Packages':'Packageはありません');const help=empty.querySelector('[data-empty-help]');help.hidden=!!query;help.textContent=document.querySelector('[data-search-scope=packages]')?(en?'Add a repository in Sources.':'Sourcesでリポジトリを追加できます。'):route==='manifests'?(en?'Packages added from files appear here.':'ファイルから追加したPackageが表示されます。'):'';}document.querySelectorAll('[data-empty-packages]').forEach(item=>{item.hidden=matches!==0;});};
if(search){search.addEventListener('input',()=>{update();syncLinks();});document.querySelector('[data-clear]').addEventListener('click',()=>{search.value='';update();syncLinks();search.focus();});}update();
const sort=document.querySelector('[data-sort]');if(sort)sort.addEventListener('change',()=>{const list=document.querySelector('[data-package-list]');[...list.children].sort((a,b)=>{const first=fixtures[a.dataset.packageTemplate||a.dataset.package].name,second=fixtures[b.dataset.packageTemplate||b.dataset.package].name;return first.localeCompare(second)*(sort.value==='desc'?-1:1);}).forEach(item=>list.appendChild(item));});
document.querySelectorAll('[data-open-management]').forEach(button=>{button.addEventListener('click',()=>{document.querySelector('[data-management="'+button.dataset.openManagement+'"]').showModal();});});
document.querySelectorAll('[data-close]').forEach(button=>{button.addEventListener('click',()=>button.closest('dialog').close());});
document.querySelectorAll('.swipe-wrap').forEach(wrapper=>{const track=wrapper.querySelector('.swipe-track'),action=wrapper.querySelector('.swipe-action');const gesture={x:0,y:0,swiped:false};wrapper.addEventListener('dragstart',event=>event.preventDefault());wrapper.addEventListener('keydown',event=>{if(!installed(wrapper.dataset.packageTemplate))return;if(event.key==='Delete'){event.preventDefault();location.href=action.href;}if(event.key==='Escape'){track.classList.remove('swipe-open');action.tabIndex=-1;}});wrapper.addEventListener('pointerdown',event=>{if(!installed(wrapper.dataset.packageTemplate))return;gesture.x=event.clientX;gesture.y=event.clientY;gesture.swiped=false;});wrapper.addEventListener('pointerup',event=>{if(!installed(wrapper.dataset.packageTemplate))return;const dx=event.clientX-gesture.x,dy=event.clientY-gesture.y;if(Math.abs(dx)>45&&Math.abs(dx)>Math.abs(dy)){gesture.swiped=true;track.classList.toggle('swipe-open',dx<0);action.tabIndex=dx<0?0:-1;}});wrapper.addEventListener('pointercancel',()=>{gesture.swiped=false;});wrapper.addEventListener('click',event=>{if(gesture.swiped){event.preventDefault();gesture.swiped=false;}},true);});
// Origin is a whitelisted list key; only Package-detail routes carry it. Tab links and other routes never receive it.
const origins = {...Object.fromEntries(Object.entries(categories).map(([key,value])=>[key,{page:value.page,label:value.name[en?1:0]}])),packages:{page:'packages',label:'Packages'},search:{page:'search-results',label:'Search'}};
const originKey = parameters.get('from'), origin = originKey && Object.hasOwn(origins,originKey) ? originKey : '';
const detailFamily = file => /^manifest-browser-(manifest|test)(-|\\.|$)/.test(file);
const carryFamily = file => /^manifest-browser-(manifest|test|script|source)(-|\\.|$)/.test(file);
const originBack = document.querySelector('[data-origin-back]');
if(origin&&originBack&&detailFamily(location.pathname.split('/').pop())){originBack.href=destination(origins[origin].page);originBack.textContent='‹ '+origins[origin].label;const tab=destination(origin==='packages'?'packages':origin==='search'?'search':'repositories');document.querySelectorAll('.tabbar a,.sidebar a').forEach(a=>{const on=a.getAttribute('href')===tab;a.classList.toggle('active',on);if(on)a.setAttribute('aria-current','page');else a.removeAttribute('aria-current');});}
const carrySearchQuery = url => {if(url.origin!==location.origin)return;const value=globalSearch&&search?search.value:parameters.get('searchQuery');if(value)url.searchParams.set('searchQuery',value);else url.searchParams.delete('searchQuery');};
const syncLinks = () => document.querySelectorAll('a[href]').forEach(anchor=>{if(anchor.getAttribute('href').startsWith('#'))return;const url=new URL(anchor.href);url.searchParams.set('demo',JSON.stringify(demo));const own=anchor.dataset.from,carry=origin&&carryFamily(url.pathname.split('/').pop())&&!anchor.closest('.tabbar,.sidebar')&&!anchor.hasAttribute('data-origin-back');const next=own&&Object.hasOwn(origins,own)?own:carry?origin:'';if(next)url.searchParams.set('from',next);else url.searchParams.delete('from');carrySearchQuery(url);anchor.href=url.href;});
syncLinks();
(${installQueueClient.toString()})({demo,fixtures,model:queueModel,catalogVersion,syncLinks,target,destination,route,origin,icons:${JSON.stringify(Object.fromEntries(Object.entries(packageFixtures).map(([id,f])=>[id,tile(f.glyph)])))}});
// Sources refresh: the pull gesture and the Refresh button share one handler. Only catalog metadata (demo.catalogRev) changes; installed versions and enabled state never do.
const refresh = document.querySelector('[data-refresh]');
if(refresh&&['repositories','sources-refreshing','sources-refreshed','sources-error'].includes(route)){
 const copy = {refreshing:en?'Refreshing sources…':'リポジトリを更新中…',error:en?'Couldn’t refresh.':'更新できませんでした。',idle:''};
 const button = refresh.querySelector('[data-refresh-button]'), text = refresh.querySelector('[data-refresh-text]'), announce = refresh.querySelector('[data-refresh-announce]'), pullText = refresh.querySelector('[data-pull-text]');
 const refreshState = {busy:false,failed:false};
 const show = state => { refresh.dataset.state=state; text.textContent=copy[state]; announce.textContent=copy[state]; button.textContent=state==='error'?(en?'Try Again':'再試行'):(en?'Refresh sources':'リポジトリを更新'); button.setAttribute('aria-disabled',String(state==='refreshing')); button.setAttribute('aria-busy',String(state==='refreshing')); };
 const startRefresh = () => {
  if(refreshState.busy||button.getAttribute('aria-disabled')==='true')return;
  refreshState.busy=true;show('refreshing');
  setTimeout(()=>{
   refreshState.busy=false;
   if(parameters.get('refresh')==='fail'&&!refreshState.failed){refreshState.failed=true;show('error');return;}
   demo.catalogRev=Math.max(demo.catalogRev,${catalogRevisions.refreshed});renderCatalog();syncLinks();show('idle');
  },900);
 };
 button.addEventListener('click',startRefresh);
 const pull = {y:0,active:false,distance:0,suppressClick:false}, ready = 36;
 const endPull = trigger => { const go=pull.active&&trigger&&pull.distance>=ready; pull.active=false; refresh.classList.remove('pulling','ready'); refresh.style.removeProperty('--pull'); if(go){pull.suppressClick=true;startRefresh();setTimeout(()=>{pull.suppressClick=false;},0);} };
 const beginPull = (y,target) => { pull.active=window.scrollY<=0&&!target.closest('input,select,button,dialog,.swipe-wrap'); pull.y=y; pull.distance=0; };
 const movePull = y => { if(!pull.active)return false; const delta=y-pull.y; if(delta<=0||window.scrollY>0){endPull(false);return false;} pull.distance=Math.min(delta*.5,96); refresh.style.setProperty('--pull',pull.distance+'px'); refresh.classList.add('pulling'); refresh.classList.toggle('ready',pull.distance>=ready); pullText.textContent=pull.distance>=ready?(en?'Release to refresh':'離して更新'):(en?'Pull to refresh':'引いて更新'); return true; };
 const area = document.querySelector('main');
 area.addEventListener('dragstart',event=>{if(pull.active)event.preventDefault();});
 area.addEventListener('click',event=>{if(pull.suppressClick){event.preventDefault();event.stopPropagation();pull.suppressClick=false;}},true);
 area.addEventListener('touchstart',event=>beginPull(event.touches[0].clientY,event.target),{passive:true});
 area.addEventListener('touchmove',event=>{if(movePull(event.touches[0].clientY)&&event.cancelable)event.preventDefault();},{passive:false});
 area.addEventListener('touchend',()=>endPull(true));area.addEventListener('touchcancel',()=>endPull(false));
 area.addEventListener('pointerdown',event=>{if(event.pointerType==='mouse'&&event.button===0)beginPull(event.clientY,event.target);});
 window.addEventListener('pointermove',event=>{if(event.pointerType==='mouse')movePull(event.clientY);});
 window.addEventListener('pointerup',event=>{if(event.pointerType==='mouse')endPull(true);});
}
// Details / Version switches content; it never scrolls to an anchor or changes installed state.
document.querySelectorAll('[data-package-panels]').forEach(group=>{
 const tabs=[...group.querySelectorAll('[data-package-tab]')],panels=[...group.querySelectorAll('[data-package-panel]')];
 const select=name=>{tabs.forEach(tab=>{const active=tab.dataset.packageTab===name;tab.classList.toggle('active',active);tab.setAttribute('aria-selected',String(active));tab.tabIndex=active?0:-1;});panels.forEach(panel=>{panel.hidden=panel.dataset.packagePanel!==name;});};
 tabs.forEach((tab,index)=>{tab.addEventListener('click',()=>select(tab.dataset.packageTab));tab.addEventListener('keydown',event=>{const next=event.key==='ArrowRight'?(index+1)%tabs.length:event.key==='ArrowLeft'?(index+tabs.length-1)%tabs.length:event.key==='Home'?0:event.key==='End'?tabs.length-1:-1;if(next>=0){event.preventDefault();select(tabs[next].dataset.packageTab);tabs[next].focus();}});});
 select(parameters.get('panel')==='version'?'version':'details');
});
const dialog=document.querySelector('dialog[data-auto]');if(dialog){dialog.showModal();dialog.addEventListener('cancel',event=>{event.preventDefault();location.href=dialog.querySelector('[data-cancel]').href;});}
</script>`;
export function manifestPage(title:string,contents:string,options:{back?:string;backPage?:string;action?:string;actionPage?:string;fullscreen?:boolean;lang:Lang;tab?:Tab;large?:boolean;donePage?:string;detailBack?:boolean;editingSources?:boolean}) {
 const lang=options.lang, en=lang==='en', active=options.tab??'Sources';
 const tabs=([['Sources','repositories','source'],['Packages','packages','package'],['Scripts','scripts','script'],['Search','search','search']] as const).map(([label,page,glyph])=>`<a class="${active===label?'active':''}" ${active===label?'aria-current="page"':''} href="${href(page,lang)}">${svg(glyph)}${label}</a>`).join('');
 const back=options.fullscreen||options.large||options.editingSources?'':link(options.backPage??'repositories',`‹ ${options.back??'Sources'}`,lang,'back',options.detailBack?'data-origin-back':'');
 const sourceControls=options.editingSources?`<span class="source-controls"><a class="action" aria-label="${en?'Add':'追加'}" href="${href('repository-add',lang)}">${svg('plus')}</a>${link('repositories',en?'Done':'完了',lang,'action')}</span>`:options.large&&active==='Sources'?link('repositories-edit',en?'Edit':'編集',lang,'action'):'';
 const action=sourceControls|| (options.fullscreen?link(options.donePage??'scripts',en?'Done':'完了',lang,'action'):options.action?link(options.actionPage??'repository-add',options.action,lang,'action'):'');
 return `<!doctype html><html lang="${lang}"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(title)}</title><style>${css}${extraCss}${referenceCss}${queueCss}</style><body class="mf ${options.fullscreen?'full':''}">${options.fullscreen?'':`<aside class="sidebar"><div class="sidebar-title">Plugins</div>${tabs}</aside>`}<div class="detail"><header><div class="status"><span>9:41</span><span>Wi-Fi ▰</span></div><div class="bar">${back||'<span class="spacer"></span>'}<strong>${options.large?'':escape(title)}</strong>${action||'<span class="spacer"></span>'}</div></header><main>${options.large?`<h1 class="large-title">${escape(title)}</h1>`:''}${contents}</main></div>${options.fullscreen?'':`<nav class="tabbar" aria-label="Plugins">${tabs}</nav>`}${options.fullscreen?'':queueBar(lang)+installSheet(lang)}${searchScript}</body></html>`;
}
export const parts={queueBar,installSheet,categoryRow,refreshControl,sortControl,updatePill,row,section,badge,statusRow,checkRow,stateRow,primaryButton,pill,codeBlock,navRow,iconRow,scriptRow,scriptDirectoryRow,scriptPackageRow,packageHero,packagePanels,versionRows,confirmation,searchField,manifestPage,href,svg,tile,repoRow,packageRow,managePill,activationRow,deleteConfirmation,scriptMatches} as const;
export type PartName=keyof typeof parts;
export function requireParts<N extends PartName>(names:readonly N[]):Pick<typeof parts,N>{
 const missing=names.filter(name=>!(name in parts));if(missing.length)throw new Error(`Missing components: ${missing.join(', ')}`);
 return Object.fromEntries(names.map(name=>[name,parts[name]])) as Pick<typeof parts,N>;
}
