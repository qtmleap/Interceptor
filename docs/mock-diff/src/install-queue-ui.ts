// Browser-only UI adapter for synthetic mock data; no network or app installation.
export function installQueueClient(ctx: any) {
 const {demo, fixtures, model, catalogVersion, syncLinks, target, destination, route, origin, icons} = ctx;
 const sheet = document.querySelector('[data-install-sheet]') as HTMLDialogElement | null;
 const tray = document.querySelector('[data-queue-tray]') as HTMLButtonElement | null;
 if (!sheet || !tray) return;
 const en = document.documentElement.lang === 'en';
 const rows = sheet.querySelector('[data-queue-items]')!;
 const confirm = sheet.querySelector('[data-queue-confirm]') as HTMLButtonElement;
 const clear = sheet.querySelector('[data-queue-clear]') as HTMLButtonElement;
 const close = sheet.querySelector('[data-queue-close]') as HTMLButtonElement;
 const status = sheet.querySelector('[data-queue-status]')!;
 const state = {phase:route==='manifest-install-queue-error'?'error':'idle', failed:route==='manifest-install-queue-error', batch:[] as any[]};
 const words = (ja:string,english:string) => en ? english : ja;
 const navigate = () => {
  const owner = (document.querySelector('[data-detail-owner]') as HTMLElement | null)?.dataset.detailOwner;
  const url = new URL(location.href);
  url.pathname = url.pathname.slice(0,url.pathname.lastIndexOf('/')+1) + destination(owner ? target(owner,demo[owner]) : route);
  url.search = ''; url.searchParams.set('demo',JSON.stringify(demo));
  if(origin)url.searchParams.set('from',origin);
  location.replace(url.href);
 };
 const closeSheet = () => { if(state.phase==='busy')return; if(state.phase==='complete'){navigate();return;} sheet.close(); };
 const render = () => {
  demo.queue = model.normalize(demo.queue);
  const pending = demo.queue;
  const busy = state.phase==='busy', complete = state.phase==='complete';
  const entries = complete ? state.batch : pending;
  const invalid = pending.filter((entry:any)=>!model.isValid(entry,demo));
  tray.hidden = pending.length===0 || complete;
  document.body.classList.toggle('has-install-queue',!tray.hidden);
  const count = tray.querySelector('[data-queue-count]')!;
  count.textContent = en ? pending.length+(pending.length===1?' Package':' Packages') : pending.length+'件';
  document.querySelectorAll('[data-install-cta]').forEach(item=>{
   const button=item as HTMLButtonElement,id=button.dataset.installCta!;
   button.hidden=!!demo[id]; button.textContent=pending.some((entry:any)=>entry.id===id)?words('キュー','Queued'):words('追加','Get');
  });
  rows.replaceChildren();
  if(!entries.length){const empty=document.createElement('p');empty.className='queue-empty';empty.textContent=words('キューは空です','Queue is empty');rows.append(empty);}
  entries.forEach((entry:any)=>{
   const valid=complete||model.isValid(entry,demo), row=document.createElement('div');row.className='queue-item';
   const remove=document.createElement('button');remove.type='button';remove.className='queue-remove';remove.textContent='−';remove.disabled=busy;remove.hidden=complete;
   remove.setAttribute('aria-label',en?'Remove '+fixtures[entry.id].name:fixtures[entry.id].name+'を取り消す');
   remove.addEventListener('click',()=>{if(state.phase==='busy')return;demo.queue=pending.filter((item:any)=>item.id!==entry.id);state.phase='idle';syncLinks();render();});
   const icon=document.createElement('span');icon.className='queue-icon';icon.innerHTML=icons[entry.id];
   const label=document.createElement('div');label.className='queue-item-label';
   const name=document.createElement('strong');name.textContent=fixtures[entry.id].name;
   const detail=document.createElement('span');detail.textContent=entry.version+' · '+(complete?words('完了','Installed'):busy?words('インストール中…','Installing…'):!valid?(entry.kind==='reinstall'?(demo[entry.id]?words('バージョンが変わりました','Version changed'):words('削除されました','No longer installed')):words('インストール済み','Already installed')):entry.kind==='reinstall'?words('再インストール','Reinstall'):words('待機中','Queued'));
   if(!valid)row.classList.add('queue-invalid');
   label.append(name,detail);row.append(remove,icon,label);rows.append(row);
  });
  close.disabled=busy;clear.disabled=busy;clear.hidden=complete||pending.length===0;
  confirm.disabled=busy||(!complete&&(!pending.length||invalid.length>0));confirm.setAttribute('aria-busy',String(busy));
  confirm.textContent=complete?words('完了','Done'):busy?words('インストール中…','Installing…'):state.phase==='error'?words('再試行','Retry'):words('インストール','Confirm');
  status.textContent=complete?words('インストールしました','Installed'):state.phase==='error'?words('インストールできませんでした','Could not install'):invalid.length?words('変更された項目を取り消してください','Remove the changed items'):'';
 };
 const open = () => {render();if(!sheet.open)sheet.showModal();};
 document.querySelectorAll('[data-install-cta]').forEach(item=>item.addEventListener('click',()=>{
  const id=(item as HTMLElement).dataset.installCta!;if(!Object.hasOwn(fixtures,id)||demo[id])return;
  if(demo.queue.some((entry:any)=>entry.id===id)){open();return;}
  demo.queue=model.enqueue(demo.queue,{id,version:catalogVersion(id),kind:'add'},demo);state.phase='idle';syncLinks();render();
 }));
 document.querySelectorAll('[data-reinstall]').forEach(item=>item.addEventListener('click',()=>{
  const id=(item as HTMLElement).dataset.reinstall!,installed=demo[id];if(!Object.hasOwn(fixtures,id)||!installed)return;
  (item.closest('dialog') as HTMLDialogElement)?.close();
  demo.queue=model.enqueue(demo.queue,{id,version:installed.version,kind:'reinstall'},demo);state.phase='idle';syncLinks();render();
 }));
 tray.addEventListener('click',open);document.querySelectorAll('[data-queue-open]').forEach(button=>button.addEventListener('click',open));close.addEventListener('click',closeSheet);
 sheet.addEventListener('cancel',event=>{event.preventDefault();closeSheet();});
 clear.addEventListener('click',()=>{if(state.phase==='busy')return;demo.queue=[];state.phase='idle';syncLinks();render();});
 confirm.addEventListener('click',()=>{
  if(state.phase==='complete'){navigate();return;}
  if(state.phase==='busy'||!demo.queue.length)return;
  const batch=model.normalize(demo.queue);
  if(!model.confirm(batch,demo).ok){render();return;}
  state.batch=batch;state.phase='busy';render();
  setTimeout(()=>{
   const result=model.confirm(batch,demo);
   if((new URLSearchParams(location.search).get('install')==='fail'&&!state.failed)||!result.ok){state.failed=true;state.phase='error';render();return;}
   Object.assign(demo,result.installed);demo.queue=[];state.phase='complete';syncLinks();render();
  },700);
 });
 render();
 const requested = new URLSearchParams(location.search).get('sheet');
 if(requested==='install'||route==='manifest-install-queue'||route==='manifest-install-queue-error')open();
 const manage = requested?.startsWith('manage:') ? requested.slice(7) : route==='manifest-manage'?'search':'';
 if(manage&&Object.hasOwn(fixtures,manage)&&demo[manage]){
  const dialog=document.querySelector('[data-management="'+manage+'"]') as HTMLDialogElement | null;
  if(dialog&&!dialog.open)dialog.showModal();
 }
}
