import {refreshStates,requireParts,type Lang,type Tab} from './manifest-components';
import {packageFixtures, categoryFixtures, publicationDates, type PackageID, type CategoryID} from './manifest-fixtures';
const {queueBar,installSheet,categoryRow,refreshControl,sortControl,updatePill,checkRow,row,section,statusRow,stateRow,primaryButton,pill,codeBlock,navRow,iconRow,scriptRow,scriptDirectoryRow,scriptPackageRow,packageHero,packagePanels,versionRows,confirmation,searchField,manifestPage,href,svg,repoRow,packageRow,managePill,activationRow,deleteConfirmation,scriptMatches}=requireParts(['queueBar','installSheet','categoryRow','refreshControl','sortControl','updatePill','checkRow','row','section','statusRow','stateRow','primaryButton','pill','codeBlock','navRow','iconRow','scriptRow','scriptDirectoryRow','scriptPackageRow','packageHero','packagePanels','versionRows','confirmation','searchField','manifestPage','href','svg','repoRow','packageRow','managePill','activationRow','deleteConfirmation','scriptMatches'] as const);
const base=`${import.meta.dir}/..`;
const outputDirectory=process.env.MANIFEST_MOCK_OUTPUT_DIR??`${base}/mocks`;
const sourceFile='scripts/request.js';
const sourceCode='Interceptor.attach({\n  request: {\n    onEnter(req, cfg) {\n      req.body.limit = 5;\n    }\n  }\n});';
const manifest={schemaVersion:2,id:'22222222-2222-4222-8222-222222222222',name:'Search limit',version:'1.0.0',publishedAt:packageFixtures.search.publishedAt,summary:'Set the search limit to 5.',matches:packageFixtures.search.matches,read:{metadata:['method','host','path'],headers:[],queryKeys:[],body:{mode:'json'}},write:{requestBody:true,responseBody:false},endpointBindings:[],settings:{}};
const generated:string[]=[];
const withDialog=(page:string,dialog:string)=>page.replace('<script>',dialog+'<script>');
async function build(lang:Lang){
 const en=lang==='en',t=(ja:string,english:string)=>en?english:ja;
 const write=async(name:string,html:string)=>{
  if(!['components','source-request','source-local','source-response','source-preview','manifest-json'].includes(name)&&(/<pre\b|Interceptor\.attach/.test(html)))throw new Error(`Unexpected code in ${name}`);
  if(['source-request','source-local','source-response','source-preview','manifest-json'].includes(name)&&(/<(input|textarea)\b|contenteditable/.test(html)))throw new Error(`Editable content in ${name}`);
  generated.push(`${name}:${lang}`);return Bun.write(`${outputDirectory}/manifest-browser-${name}${en?'-en':''}.html`,html);
 };
 const shell=(title:string,content:string,tab:Tab='Sources',back='Sources',backPage='repositories',large=false,detailBack=false)=>manifestPage(title,content,{lang,tab,back,backPage,large,detailBack});
 // Synthetic category values use supported optional native/producer display metadata.
 const categoryIDs=Object.keys(categoryFixtures) as CategoryID[];
 const inCategory=(category:CategoryID)=>(Object.keys(packageFixtures) as PackageID[]).filter(id=>packageFixtures[id].category===category);
 const categoryName=(category:CategoryID)=>categoryFixtures[category].name[en?1:0];
 const categoryPage=(category:CategoryID,query='')=>searchField(lang,query,'category')+`<div class="catalog edge-list">${inCategory(category).map(id=>packageRow(id,lang,false,category)).join('')}</div>`;
 const repoHero=packageHero('Example Repository','example.com','','source',lang);
 const repoDetails=section(t('リポジトリ情報','Repository Information'),row('URL','https://example.com/repository.json')+row(t('更新番号','Update number'),'12').replace('12</div>','<span data-catalog-rev>12</span></div>')+stateRow('trusted',lang));
 const categoryList=()=>`<h2 class="section-title">${t('カテゴリ','Categories')}</h2><div class="edge-list">${(['requests','responses'] as const).map(id=>categoryRow(id,String(inCategory(id).length),lang)).join('')}</div>`;
 const categories=()=>categoryList()+repoDetails;
 const versions=(version:string,owner?:PackageID,updatable=false)=>`<section aria-label="${t('バージョン','Version')}" ${owner?`data-version-owner="${owner}"`:''}><div class="group">${versionRows(lang,version,owner?publicationDates[owner]?.[version]:undefined)}${owner&&updatable?`<div class="row" data-version-update-row hidden>${updatePill(owner,lang)}</div>`:''}</div></section>`;
 const packagePage=(content:string,id:PackageID,fromSource=false)=>{const category=packageFixtures[id].category;return shell(packageFixtures[id].name,`<div class="detail-view">${content}</div>`,fromSource?'Sources':'Packages',fromSource?categoryName(category):'Packages',fromSource?categoryFixtures[category].page:'packages',false,true);};
 const contents=(id:PackageID)=>section(t('内容','Contents'),navRow('Scripts','script-package-'+id,lang,t(`${packageFixtures[id].files.length}件`,`${packageFixtures[id].files.length} files`))+(id==='search'?navRow('Manifest JSON','manifest-json',lang):''));
 const detail=(id:PackageID,version:string,installed=true,action?:string,fromSource=false)=>{
  const f=packageFixtures[id];
  const hero=packageHero(f.name,f.summary[en?1:0],action??(installed?managePill(id,lang):`<button type="button" class="pill" data-install-cta="${id}">${t('追加','Get')}</button>`),f.glyph,lang);
  const activation=installed?`<div data-activation-section="${id}">${section('',activationRow(id,lang))}</div>`:'';
  const provenance=section('Repository',navRow(f.source==='local'?t('ローカル','Local'):'Example Repository',f.source==='local'?'manifests':'repository-overview',lang));
  const metadata=section('',row(t('作者','Author'),f.author));
  return packagePage(hero+packagePanels(id,lang,metadata+activation+provenance+contents(id),versions(version,id,installed&&id==='search')),id,fromSource);
 };
 const packages=()=>searchField(lang,'','packages')+sortControl(lang)+`<div class="catalog edge-list" data-package-list>${(['preview','search'] as const).map(id=>packageRow(id,lang,true,'packages')).join('')}</div>`;
 const fileList=(['local','search','preview'] as const).map(id=>`<div data-script-owner="${id}">${scriptPackageRow(id,lang)}</div>`).join('');
 // Global Search tab: idle, no source and no match keep the result area blank; loading and errors remain separate.
 const searchResults=(query:string)=>searchField(lang,query,'global')+`<div class="catalog edge-list" data-search-results>${(['preview','search'] as const).map(id=>packageRow(id,lang,false,'search')).join('')}</div>`;
 const sources=()=>refreshControl('idle',lang)+`<h2 class="section-title">Repositories</h2><div class="edge-list">${repoRow('Example Repository','https://example.com/repository.json','2','repository-overview',lang,'source','repo',true)+repoRow(t('ローカル','Local'),t('ファイルから追加したPackage','Packages added from files'),'1','manifests',lang,'local','local')}</div><p class="repository-foot"><span data-count="sources">1</span> ${t('リポジトリ','source')}</p>`;
 // Define changed component states in the catalog before composing screen outputs.
 await write('components',shell(t('共通コンポーネント','Components'),section(t('キュー','Install queue'),queueBar(lang,true))+section(t('操作シート','Installed actions'),managePill('local',lang))+section(t('カテゴリの行','Category rows'),`<div class="edge-list">${categoryIDs.filter(id=>id!=='local').map(id=>categoryRow(id,String(inCategory(id).length),lang)).join('')}</div>`,t('カテゴリ名・件数はサンプルです。','Category names and counts are sample data.'))+section(t('更新操作','Refresh'),refreshStates.map(state=>refreshControl(state,lang)).join(''),t('待機中は何も表示せず、Refreshボタンは読み上げとキーボード操作で使えます。','Idle shows nothing; the Refresh button stays available to screen readers and keyboard focus.'))+section(t('リポジトリの行','Source rows'),`<div class="edge-list">${repoRow('Example Repository','https://example.com/repository.json','2','repository-overview',lang)}</div>`)+section(t('Packageの行と削除','Package rows and deletion'),`<div class="edge-list">${packageRow('local',lang,true)}</div>`)+searchField(lang)+sortControl(lang)+packageHero('Search limit',packageFixtures.search.summary[en?1:0],managePill('search',lang),'search',lang)+packagePanels('search',lang,section('',row(t('作者','Author'),packageFixtures.search.author)),versions('1.0.0','search'))+section(t('実行状態','Execution'),activationRow('local',lang))+`<div class="hero-action"><button class="pill disabled" disabled>${t('追加','Add')}</button><button class="pill disabled" disabled aria-busy="true">${t('追加中…','Adding…')}</button></div>`+versions('1.0.0','preview')+confirmation(t('Search limitを有効にしますか？','Enable Search limit?'),'OK',t('キャンセル','Cancel'),lang,'manifest',true)+scriptMatches('search',sourceFile,lang)+section(t('フォルダ','Folders'),scriptDirectoryRow('scripts','script-folder-search-scripts',lang))+section(t('ファイル','Files'),scriptRow('request.js','',lang))));
 await write('repositories',shell('Sources',sources(),'Sources','Sources','repositories',true));
 await write('sources-refreshing',shell('Sources',sources().replace(refreshControl('idle',lang),refreshControl('refreshing',lang)),'Sources','Sources','repositories',true));
 await write('sources-refreshed',shell('Sources',sources(),'Sources','Sources','repositories',true));
 await write('sources-error',shell('Sources',sources().replace(refreshControl('idle',lang),refreshControl('error',lang)),'Sources','Sources','repositories',true));
 await write('repositories-edit',manifestPage('Sources',sources().replace(refreshControl('idle',lang),'')+section('',`<a class="row error" data-source-row href="${href('repositories',lang)}?removeSource=repo">${t('Example Repositoryを削除','Delete Example Repository')}</a>`,t('インストール済みのPackageは残ります。','Installed Packages are kept.')),{lang,tab:'Sources',action:t('完了','Done'),actionPage:'repositories',editingSources:true}));
 // Repository page: Categories only. repository, repository-update and repository-current stay as compatibility aliases of the corrected layout.
 for(const name of ['repository-overview','repository','repository-update','repository-current'])await write(name,shell('Example Repository',categories()));
 await write('all-packages',shell('Sources',sources().replace(refreshControl('idle',lang),''),'Sources','Sources','repositories',true));
 for(const category of ['requests','responses'] as const)await write(`category-${category}`,shell(categoryName(category),categoryPage(category),'Sources','Example Repository','repository-overview'));
 await write('repository-search',shell(categoryName('requests'),categoryPage('requests','Search'),'Sources','Example Repository','repository-overview'));
 await write('repository-search-empty',shell(categoryName('requests'),categoryPage('requests','missing'),'Sources','Example Repository','repository-overview'));
 await write('repository-catalog-empty',shell('Example Repository',repoHero+section('',statusRow('neutral',t('Packageがありません','No Packages')),t('このリポジトリにはPackageが登録されていません。','This repository has no Packages.'))+primaryButton(t('Sourcesへ戻る','Back to Sources'),'repositories',lang)));
 await write('repository-catalog-loading',shell('Example Repository',repoHero+section('',checkRow('checking',lang))+`<a class="text-link" href="${href('repository',lang)}?addSource=repo">${t('カテゴリへ','View Categories')}</a>`));
 await write('repository-add',shell(t('リポジトリを追加','Add Repository'),`<label class="field-label" for="repository-url">URL</label><input class="field" id="repository-url" type="url" value="https://example.com/repository.json" aria-label="Repository URL">`+primaryButton(t('リポジトリを追加','Add Repository'),'repository',lang).replace('.html"','.html?addSource=repo"')+`<p class="footer">${t('必要なPackageを選んで追加します。','Choose the Packages you want to add.')}</p>`));
 await write('manifests',shell(t('ローカル','Local'),searchField(lang,'','category')+`<div class="catalog edge-list">${packageRow('local',lang,false,'local')}</div>`,'Sources','Sources','repositories'));
 await write('packages',shell('Packages',packages(),'Packages','Sources','repositories',true));
 await write('packages-added',shell('Packages',packages(),'Packages','Sources','repositories',true));
 await write('packages-repository',shell('Packages',packages(),'Packages','Sources','repositories',true));
 await write('manifest',detail('search','1.0.0'));
 await write('manifest-import',detail('search','1.0.0',false,undefined,true));
 await write('manifest-install-queue',detail('search','1.0.0',false,undefined,true));
 await write('manifest-install-queue-error',detail('search','1.0.0',false,undefined,true));
 await write('manifest-manage',detail('search','1.0.0'));
 await write('manifest-added',detail('search','1.0.0'));
 await write('manifest-confirm',withDialog(detail('search','1.0.0'),confirmation(t('Search limitを有効にして、対象の通信を変更しますか？','Enable Search limit and change matching traffic?'),'OK',t('キャンセル','Cancel'),lang)));
 await write('manifest-preview',detail('preview','1.0.0',false,undefined,true));
 await write('manifest-preview-added',detail('preview','1.0.0'));
 await write('manifest-preview-confirm',withDialog(detail('preview','1.0.0'),confirmation(t('Response previewを有効にしますか？','Enable Response preview?'),'OK',t('キャンセル','Cancel'),lang,'manifest-preview-enabled',false,'manifest-preview-added')));
 await write('manifest-preview-enabled',detail('preview','1.0.0'));
 await write('manifest-local',detail('local','1.0.0'));
 await write('manifest-local-confirm',withDialog(detail('local','1.0.0'),confirmation(t('Local exampleを有効にして、対象の通信を変更しますか？','Enable Local example and change matching traffic?'),'OK',t('キャンセル','Cancel'),lang,'manifest-local-enabled',false,'manifest-local')));
 await write('manifest-local-enabled',detail('local','1.0.0'));
 await write('manifest-update',detail('search','1.0.0'));
 // Compatibility URLs display the same single installed version; no pending-revision step.
 await write('manifest-enable',detail('search','2.0.0'));
 await write('manifest-replace-confirm',detail('search','2.0.0'));
 await write('manifest-updated',detail('search','2.0.0'));
 await write('manifest-disabled-update',detail('search','2.0.0'));
 await write('manifest-disabled-confirm',withDialog(detail('search','2.0.0'),confirmation(t('Search limitを有効にして、対象の通信を変更しますか？','Enable Search limit and change matching traffic?'),'OK',t('キャンセル','Cancel'),lang,'manifest-updated',false,'manifest-disabled-update')));
 for(const id of ['search','preview','local'] as const){const name=id==='search'?'manifest-delete-confirm':`manifest-${id}-delete-confirm`;await write(name,withDialog(detail(id,'1.0.0'),deleteConfirmation(id,lang)));}
 await write('search',shell('Search',searchResults(''),'Search','Sources','repositories',true));
 await write('search-results',shell('Search',searchResults('example'),'Search','Sources','repositories',true));
 await write('search-empty',shell('Search',searchResults('missing'),'Search','Sources','repositories',true));
 await write('search-no-source',shell('Search',searchResults(''),'Search','Sources','repositories',true));
 await write('scripts',shell('Scripts',fileList,'Scripts','Packages','packages',true));
 const folderPage=(owner:PackageID,path:string)=>'script-folder-'+owner+'-'+encodeURIComponent(path).replaceAll('%','_');
 for(const owner of ['local','search','preview'] as const){
   const paths=packageFixtures[owner].files;
   const directories=[...new Set(paths.flatMap(file=>file.split('/').slice(0,-1).map((_,i)=>file.split('/').slice(0,i+1).join('/'))))].sort();
   for(const directory of ['',...directories]){
     const depth=directory?directory.split('/').length:0;
     const children=paths.filter(file=>!directory||file.startsWith(directory+'/'));
     const folders=[...new Set(children.filter(file=>file.split('/').length>depth+1).map(file=>file.split('/')[depth]))].sort();
     const files=children.filter(file=>file.split('/').length===depth+1).sort();
     const content=section(directory?packageFixtures[owner].name+' / '+directory:packageFixtures[owner].name,folders.map(name=>scriptDirectoryRow(name,folderPage(owner,[directory,name].filter(Boolean).join('/')),lang)).join('')+files.map(file=>scriptRow(file.split('/').pop()!,'',lang,owner)).join(''));
     const parent=directory.split('/').slice(0,-1).join('/');
     await write(directory?folderPage(owner,directory):'script-package-'+owner,shell(directory?directory.split('/').pop()!:packageFixtures[owner].name,content,'Scripts',directory?(parent?parent.split('/').pop()!:packageFixtures[owner].name):'Scripts',directory?(parent?folderPage(owner,parent):'script-package-'+owner):'scripts'));
   }
 }
 const responseCode='Interceptor.attach({\n  response: {\n    onLeave(res, cfg) {\n      console.log(res.body);\n    }\n  }\n});';
 const sourceViewer=(owner:PackageID,file:string,code:string)=>manifestPage(file.split('/').pop()!,section('',codeBlock(code)),{lang,tab:'Scripts',fullscreen:true,donePage:file.includes('/')?folderPage(owner,file.split('/').slice(0,-1).join('/')):'script-package-'+owner});
 await write('source-request',sourceViewer('search',sourceFile,sourceCode));
 await write('source-local',sourceViewer('local',sourceFile,sourceCode));
 await write('source-response',sourceViewer('search','scripts/response.js',responseCode));
 await write('source-preview',sourceViewer('preview','scripts/response.js',responseCode));
 await write('manifest-json',manifestPage('Manifest JSON',section('',codeBlock(JSON.stringify(manifest,null,2)).replace('<pre class="code"','<pre data-manifest-json class="code"')),{lang,tab:'Packages',fullscreen:true,donePage:'manifest'}));
 await write('empty',shell('Sources',section('',statusRow('neutral',t('リポジトリがありません','No repositories')),t('リポジトリを追加してPackageを探せます。','Add a repository to browse its Packages.'))+primaryButton(t('リポジトリを追加','Add Repository'),'repository-add',lang),'Sources','Sources','repositories',true));
 await write('error',shell('Example Repository',repoHero+section('',statusRow('error',t('一覧を取得できませんでした','Could not load the catalog')),t('接続を確認して、もう一度お試しください。','Check your connection and try again.'))+primaryButton(t('再試行','Try Again'),'repositories',lang)+categoryList()));
}
await build('ja');await build('en');console.log(`Built ${generated.length/2} Manifest browser screens in JA/EN.`);
