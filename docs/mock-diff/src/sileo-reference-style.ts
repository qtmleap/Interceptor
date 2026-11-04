// Screenshot-derived (Sileo IMG_0001–0004) MF-only overrides. Append after css + extraCss.
export const referenceCss = `
.mf{--ui-font:-apple-system,BlinkMacSystemFont,"SF Pro Text","Hiragino Sans",sans-serif;font-family:var(--ui-font)}
.mf button,.mf input,.mf select,.mf .primary{font-family:inherit}
.mf{--bg:#fff;--surface:#f2f2f7;--line:#c6c6c8;--ink:#000;--muted:#6d6d72;--accent:#2f8f9d;--buttonInk:#fff;--danger:#ef5648;--ok:#5ed855;overflow-x:hidden}
.mf *{box-sizing:border-box}
.mf a:focus-visible,.mf button:focus-visible,.mf input:focus-visible,.mf select:focus-visible,.mf [tabindex]:focus-visible{outline:3px solid var(--accent);outline-offset:-3px;border-radius:6px}
.mf header{height:88px}.mf header .status{height:38px}.mf .bar{height:50px}
.mf main{padding:0 0 96px;overflow-x:hidden}
.mf .large-title{font-size:34px;line-height:1.12;font-weight:800;letter-spacing:-.6px;margin:8px 16px 18px}
.mf .section-title,.mf main h2{font-size:22px;line-height:1.2;font-weight:800;margin:36px 16px 14px;color:var(--ink)}
.mf section{margin-top:0}
.mf .footer,.mf .repository-foot{margin:0;padding:10px 16px;font-size:13px;color:var(--muted)}
.mf .tabbar{border-top:.5px solid var(--line)}
.mf .tabbar svg{width:25px;height:25px}

.mf .edge-list{background:none;border-radius:0;border-top:.5px solid var(--line);margin:0}
.mf .edge-list>*:last-child{border-bottom:.5px solid var(--line)}
.mf .source-summary,.mf .repo-row,.mf .package-row{display:flex;align-items:center;gap:14px;min-height:55px;padding:7px 16px;position:relative;background:var(--bg);color:var(--ink);width:100%}
.mf .source-summary{min-height:66px;margin:18px 0 0;border-top:.5px solid var(--line);border-bottom:.5px solid var(--line)}
.mf .repo-row{min-height:55px;padding:8px 16px}
.mf .repo-row+.repo-row:before,.mf .package-row+.package-row:before,.mf .swipe-wrap+.swipe-wrap:before{content:"";position:absolute;top:0;left:70px;right:0;border-top:.5px solid var(--line)}
.mf .source-summary .tile,.mf .repo-row .tile,.mf .package-row .tile{width:40px;height:40px;border-radius:9px;flex:none}
.mf .source-summary .tile svg,.mf .repo-row .tile svg,.mf .package-row .tile svg{width:24px;height:24px}
.mf .source-summary .label,.mf .repo-row .label,.mf .package-row .label{flex:1;min-width:0}
.mf .source-summary strong,.mf .repo-row strong,.mf .package-row strong{display:block;font-size:17px;line-height:1.2;font-weight:600;overflow-wrap:anywhere}
.mf .source-summary .sub,.mf .repo-row .sub,.mf .repo-row .repo-url{display:block;font-size:13px;line-height:1.3;color:var(--muted);overflow-wrap:anywhere}
.mf .trailing-count{display:flex;align-items:center;gap:8px;flex:none;font-size:13px;color:var(--muted)}
.mf .trailing-count .chevron{font-size:24px;line-height:1;color:var(--muted)}

.mf .package-row{align-items:flex-start;padding:10px 16px;min-height:66px}
.mf .package-row .tile{position:relative;margin-top:0;overflow:visible}
.mf .package-row .meta,.mf .package-row .version{display:block;font-size:14px;line-height:1.3;color:var(--muted);overflow-wrap:anywhere}
.mf .package-row .sub{display:block;font-size:13px;line-height:1.3;color:var(--muted);overflow-wrap:anywhere}
.mf .install-badge{position:absolute;right:-4px;bottom:-4px;width:14px;height:14px;border-radius:50%;background:var(--ok);color:#fff;display:flex;align-items:center;justify-content:center;border:0;box-shadow:none}
.mf .install-badge svg{width:10px;height:10px;stroke-width:3}
.mf .installed-heading{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin:30px 16px 10px;font-size:22px;font-weight:800}
.mf .installed-heading h2{margin:0;font-size:inherit}
.mf .sort-select{appearance:none;border:0;background:transparent;color:var(--accent);font-size:17px;min-height:44px;padding:0 4px;cursor:pointer}
.mf .search-box{margin:12px 16px 0;border-radius:12px;min-height:44px;background:var(--surface)}
.mf .search-box input{font-size:17px}

.mf .swipe-wrap{position:relative;overflow:hidden;touch-action:pan-y;width:100%}
.mf .swipe-track{display:flex;width:calc(100% + 80px);transition:transform .2s ease}
.mf .swipe-track>.package-row,.mf .swipe-track>.row{flex:0 0 calc(100% - 80px);width:calc(100% - 80px)}
.mf .swipe-action{flex:0 0 80px;width:80px;min-height:100%;border:0;background:var(--danger);color:#fff;font-size:15px;font-weight:500;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;padding:0}
.mf .swipe-action svg{width:22px;height:22px}
.mf .swipe-open{transform:translateX(-80px)}
.mf .swipe-wrap:focus-within .swipe-track{transform:translateX(-80px)}

.mf .package-banner{display:flex;flex-direction:column;gap:10px;padding:12px 16px 14px;margin:0;border-bottom:.5px solid var(--line);min-height:120px;max-height:none}
.mf .package-profile{display:flex;align-items:flex-start;gap:14px;min-width:0}
.mf .package-profile .tile.large,.mf .package-banner .tile.large{width:60px;height:60px;border-radius:14px;flex:none}
.mf .package-profile .tile.large svg{width:34px;height:34px}
.mf .profile-copy{flex:1;min-width:0}
.mf .profile-copy h1{font-size:22px;line-height:1.15;margin:0 0 4px;font-weight:700;letter-spacing:-.3px;overflow-wrap:anywhere}
.mf .target-summary{display:block;min-width:0}
.mf .host-line{display:block;font-size:13px;line-height:1.3;color:var(--ink);overflow-wrap:anywhere;word-break:break-word;white-space:normal}
.mf .host-line b,.mf .host-line strong{color:var(--muted);font-weight:500}
.mf .profile-actions{display:flex;align-items:center;gap:10px;flex:none}
.mf .profile-actions .pill,.mf .package-banner .pill{min-height:32px;padding:4px 18px;font-size:15px;border-radius:16px}
.mf .package-banner>.profile-actions{justify-content:flex-end}
.mf .detail-tabs{display:flex;gap:0;margin:0 16px}
.mf .detail-tabs a,.mf .detail-tabs button{flex:1;min-height:44px;display:flex;align-items:center;justify-content:center;border:0;background:none;color:var(--muted);font-size:15px;font-weight:600;position:relative}
.mf .detail-tabs .active,.mf .detail-tabs [aria-current]{color:var(--accent)}
.mf .detail-tabs .active:after,.mf .detail-tabs [aria-current]:after{content:"";position:absolute;left:12px;right:12px;bottom:0;height:2px;background:var(--accent)}
.mf .detail-view{padding:0;margin:0}
.mf .detail-view .group{border-radius:0;margin:0}
.mf .management{display:flex;flex-direction:column;margin:16px 16px 0;border-radius:12px;background:var(--surface);overflow:hidden}
.mf .management>*{min-height:44px;display:flex;align-items:center;padding:0 16px;color:var(--accent);border:0;background:none;text-align:left}
.mf .management>*+*{border-top:.5px solid var(--line)}
.mf .management .destructive{color:var(--danger)}
.mf .togglink{color:var(--accent);min-height:44px;display:inline-flex;align-items:center;font-size:17px;border:0;background:none;padding:0 16px}
.mf .toggle{display:flex;align-items:center;justify-content:space-between;gap:12px;min-height:48px;padding:0 16px}
.mf .empty{padding:40px 24px;color:var(--muted);text-align:center}

.mf .catalog .package-row{padding:10px 16px;align-items:flex-start}
.mf .package-row .package-meta{display:block;font-size:14px;line-height:1.3;color:var(--muted);margin:2px 0;overflow-wrap:anywhere}
/* Integration: action popover, labeled match facts and readonly section rows. */
.mf .package-icon{position:relative;display:block;flex:none}
.mf .host-line>span{display:block;color:var(--muted);font-size:12px}
.mf .host-line>strong{display:block;color:var(--ink);font-size:15px;font-weight:600}
.mf .package-banner{background:var(--bg);min-height:142px}
.mf .profile-actions{justify-content:flex-end}
.mf .detail-view .package-purpose{margin:16px;font-size:16px;line-height:1.45}
.mf .detail-view .row{padding-left:16px;padding-right:16px}
.mf .togglink{display:flex;width:100%;color:var(--ink);justify-content:space-between;min-height:52px}
.mf .toggle{width:44px;height:27px;min-height:0;padding:3px;border-radius:20px;background:var(--muted);display:block;position:relative}
.mf .toggle:after{content:"";display:block;width:21px;height:21px;border-radius:50%;background:#fff}
.mf [aria-checked="true"] .toggle{background:var(--accent)}
.mf [aria-checked="true"] .toggle:after{transform:translateX(17px)}
.mf dialog.management{margin:auto;padding:0;width:290px;display:block;text-align:center}
.mf dialog.management>h3{display:block;min-height:0;color:var(--ink);margin:0;padding:20px 18px;text-align:center}
.mf dialog.management>.dialog-actions{display:flex;padding:0}
.mf .dialog-actions button{flex:1;min-height:46px;border:0;background:none;color:var(--accent)}
.mf .dialog-actions .error{color:var(--danger);font-weight:600}
.mf .swipe-wrap:focus-within .swipe-track:not(.swipe-open){transform:none}
.mf .result-count{margin:10px 16px}
.mf .field-label{margin:20px 16px 8px}.mf .field{margin:0 16px;width:calc(100% - 32px)}
.mf .primary{margin:20px 16px 0;width:calc(100% - 32px)}
@media(prefers-color-scheme:dark){
.mf{--bg:#1e1e1e;--surface:#303033;--line:#38383a;--ink:#fff;--muted:#98989d;--accent:#55acb9;--buttonInk:#102f33;--danger:#ef5648;--ok:#66dd5b}
.mf header{background:var(--bg)}.mf .tabbar{background:#1e1e1e}
.mf .source-summary,.mf .repo-row,.mf .package-row{background:var(--bg)}

.mf .tile{filter:none}
}

@media(max-width:699px) and (max-height:700px){
.mf header{height:64px}.mf header .status{height:20px;padding-top:2px}.mf .bar{height:44px}
.mf .tabbar{height:50px;padding:4px 8px 4px;gap:4px}.mf .tabbar a{gap:1px;font-size:10px}.mf .tabbar svg{width:22px;height:22px}
.mf main{padding-bottom:64px}
.mf .large-title{margin:4px 16px 12px}
.mf .package-banner{padding-top:8px;padding-bottom:10px}
}
@media(max-width:420px){
.mf .package-banner{padding-left:12px;padding-right:12px}
.mf .package-profile{gap:12px}
.mf .package-profile .tile.large{width:56px;height:56px}
}
@media(min-width:700px){
.mf .detail{margin-left:248px}.mf main{padding:0 0 48px}.mf .large-title,.mf .section-title,.mf main h2{margin-left:24px;margin-right:24px}
.mf .source-summary,.mf .repo-row,.mf .package-row{padding-left:24px;padding-right:24px}
.mf .detail-tabs{margin:0 24px}
}
/* Sources refresh, category rows and Packages sort row. Idle refresh is visually absent; the button is revealed on focus. */
.mf .sr-only{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
.mf .refresh{--pull:0px;position:relative;margin:0}
.mf .pull-indicator{height:0;overflow:hidden;display:flex;align-items:center;justify-content:center;gap:8px;color:var(--muted);font-size:13px;transition:height .15s ease}
.mf .refresh.pulling .pull-indicator{height:var(--pull);transition:none}
.mf .refresh.ready .pull-indicator{color:var(--accent)}
.mf .refresh-row{display:flex;align-items:center;gap:10px;min-height:44px;padding:0 16px;color:var(--muted);font-size:14px}
.mf .refresh[data-state="idle"] .refresh-row:not(:focus-within){position:absolute;width:1px;height:1px;min-height:0;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.mf .refresh[data-state="error"] .refresh-row{color:var(--danger)}
.mf .refresh[data-state="refreshed"] .refresh-row{color:var(--muted)}
.mf .refresh-text{flex:1;min-width:0}
.mf .refresh-button{border:0;background:none;color:var(--accent);min-height:44px;padding:0 4px;font-size:15px;font-weight:600;flex:none}
.mf .refresh[data-state="refreshing"] .refresh-button,.mf .refresh[data-state="refreshed"] .refresh-button{display:none}
.mf .spinner{display:none;width:16px;height:16px;border-radius:50%;border:2px solid var(--line);border-top-color:var(--accent);flex:none}
.mf .pull-indicator .spinner{display:inline-block}
.mf .refresh[data-state="refreshing"] .row-spinner{display:inline-block;animation:mf-spin .8s linear infinite}
@keyframes mf-spin{to{transform:rotate(360deg)}}
.mf .sort-row{display:flex;justify-content:flex-end;margin:6px 16px 0}
.mf .category-row .label strong{font-weight:600}
@media(min-width:700px){.mf .refresh-row{padding:0 24px}.mf .sort-row{margin:6px 24px 0}}
@media(prefers-reduced-motion:reduce){.mf .refresh[data-state="refreshing"] .row-spinner{animation:none}.mf .pull-indicator{transition:none}}
@media(prefers-reduced-motion:reduce){.mf .swipe-track{transition:none}}
`;

// Sileo-style install queue and installed operations, scoped to the mock browser.
export const queueCss = `
.mf .queue-tray{position:fixed;left:0;right:0;bottom:78px;z-index:5;width:100%;min-height:64px;border:0;border-top:.5px solid var(--line);background:var(--bg);color:var(--ink);display:flex;align-items:center;justify-content:space-between;padding:10px 16px;text-align:left;font:15px var(--ui-font)}
.mf .queue-tray>span:first-child{color:var(--muted)}.mf .queue-tray strong{display:block;font-size:18px;margin-top:4px}.mf .queue-tray>svg{width:22px;height:14px;fill:none;stroke:var(--accent);stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.mf.has-install-queue main{padding-bottom:166px}.mf .queue-preview{position:static;border-bottom:.5px solid var(--line)}
.mf dialog.action-sheet{position:fixed;inset:auto 8px 16px;margin:0 auto;padding:0;width:calc(100% - 16px);max-width:560px;border:0;background:none;color:var(--accent);overflow:visible}
.mf .action-sheet::backdrop,.mf .install-sheet::backdrop{background:#0008}
.mf .install-sheet h2[tabindex="-1"]:focus-visible{outline:none}
.mf .sheet-options{border-radius:14px;background:var(--surface);overflow:hidden}.mf .sheet-options>*{display:flex;width:100%;justify-content:center;align-items:center;min-height:56px;padding:12px;border:0;background:none;color:var(--accent);font:20px var(--ui-font);text-decoration:none}
.mf .sheet-options>*+*{border-top:.5px solid var(--line)}.mf .sheet-options .sheet-delete{color:var(--danger)}.mf .sheet-cancel{display:block;width:100%;min-height:56px;border:0;border-radius:14px;margin:8px 0 0;background:var(--surface);color:var(--accent);font:600 20px var(--ui-font)}
.mf dialog.install-sheet{position:fixed;inset:24px 0 0;margin:0 auto;width:100%;max-width:640px;height:calc(100dvh - 24px);max-height:calc(100dvh - 24px);padding:0;border:0;border-radius:16px 16px 0 0;background:var(--bg);color:var(--ink);overflow:hidden}
.mf .sheet-dismiss{display:block;width:100%;height:44px;border:0;background:none;color:var(--muted);font:700 32px var(--ui-font)}
.mf .sheet-dismiss svg{width:36px;height:16px;fill:none;stroke:currentColor;stroke-width:5;stroke-linecap:round;stroke-linejoin:round}
.mf .install-sheet h2{font-size:22px;margin:12px 16px 0;padding:0 0 14px;border-bottom:.5px solid var(--line)}
.mf .queue-items{padding:0 16px;overflow:auto;max-height:calc(100dvh - 290px)}.mf .queue-item{display:flex;align-items:flex-start;gap:16px;padding:12px 0}.mf .queue-item+.queue-item{border-top:.5px solid var(--line)}
.mf .queue-remove{width:24px;height:24px;min-width:24px;border:0;border-radius:50%;margin-top:8px;background:var(--danger);color:white;font:22px/1 var(--ui-font);padding:0}
.mf .queue-icon .tile{width:40px;height:40px;border-radius:9px}.mf .queue-icon .tile svg{width:24px;height:24px}.mf .queue-item-label{min-width:0;flex:1}.mf .queue-item-label strong{display:block;font-size:18px;overflow-wrap:anywhere}.mf .queue-item-label span{display:block;color:var(--muted);font-size:14px;margin-top:3px}.mf .queue-invalid .queue-item-label span{color:var(--danger)}
.mf .queue-status{margin:12px 16px;font-size:14px;color:var(--muted)}.mf .queue-status:empty{display:none}.mf .queue-empty{padding:20px 0;color:var(--muted)}
.mf .queue-footer{position:absolute;left:20px;right:20px;bottom:max(16px,env(safe-area-inset-bottom));display:flex;flex-direction:column;gap:10px}
.mf .queue-confirm{min-height:50px;border:0;border-radius:12px;background:var(--accent);color:var(--buttonInk);font:600 18px var(--ui-font)}.mf .queue-clear{min-height:44px;border:0;background:none;color:var(--accent);font:600 17px var(--ui-font)}
.mf .install-sheet button:disabled{opacity:.45}.mf .sheet-options button:disabled{opacity:.45}
@media(min-width:700px){.mf .queue-tray{left:248px;width:calc(100% - 248px);bottom:0}.mf dialog.action-sheet{left:264px;right:16px;max-width:520px}.mf dialog.install-sheet{inset:40px 16px 40px 264px;width:calc(100% - 280px);height:calc(100dvh - 80px);max-height:calc(100dvh - 80px);border-radius:16px}.mf .queue-items{max-height:calc(100dvh - 350px)}}
@media(max-width:699px) and (max-height:700px){.mf .queue-tray{bottom:50px}.mf.has-install-queue main{padding-bottom:140px}.mf dialog.install-sheet{inset:20px 0 0;height:calc(100dvh - 20px);max-height:calc(100dvh - 20px)}}
`;
