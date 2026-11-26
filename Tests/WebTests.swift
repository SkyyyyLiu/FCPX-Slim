import AppKit
import WebKit

final class WebTests: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var web: WKWebView!
    var ran = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "slim")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 760), configuration: config)
        web.navigationDelegate = self
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { if !self.ran { print("FAIL UI did not initialize"); exit(1) } }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !ran, (message.body as? [String: Any])?["command"] as? String == "ready" else { return }
        ran = true
        do {
            let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
            let result = try SlimCore(journal: fixture.deletingLastPathComponent().appendingPathComponent("unused.json")).scan(fixture)
            let json = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
            let script = """
            (()=>{
              on=false; const checks=[],soundEvents=[];
              const originalBurst=SFX.burst,originalSuction=SFX.suction,originalEmpty=SFX.empty,originalDone=SFX.done;
              SFX.burst=(...a)=>{soundEvents.push('burst');return originalBurst(...a)};
              SFX.suction=(before,after,dt)=>{if(after>before)soundEvents.push('suction');return originalSuction(before,after,dt)};
              SFX.empty=(...a)=>{soundEvents.push('empty');return originalEmpty(...a)};
              SFX.done=(...a)=>{soundEvents.push('done');return originalDone(...a)};
              const assert=(v,n)=>{if(!v)throw Error(n);checks.push('PASS '+n)};
              assert(typeof nativeEvent==='function','native UI initialized');
              const footer=document.querySelector('.app-footer'),footerGlyphs=[...document.querySelectorAll('.footer-icons>svg')],avatar=document.querySelector('.creator-avatar');
              assert(footer&&footerGlyphs.length===7&&document.querySelector('.footer-icons').getAttribute('aria-hidden')==='true','footer shows seven decorative approved icons');
              assert(footerGlyphs.every((svg,i)=>svg.dataset.icon===MEDIA_ICONS[i].key&&svg.querySelectorAll('circle').length===MEDIA_ICONS[i].dots.length&&[...svg.querySelectorAll('circle')].every((dot,j)=>+dot.getAttribute('cx')===MEDIA_ICONS[i].dots[j][0]+.5&&+dot.getAttribute('cy')===MEDIA_ICONS[i].dots[j][1]+.5)),'footer reuses all seven approved glyphs without changing their pixels');
              assert(avatar.src.startsWith('data:image/png;base64,')&&getComputedStyle(avatar).borderRadius==='50%'&&avatar.width===34&&avatar.height===34,'original portrait is embedded offline and displayed through circular mask');
              assert([...document.querySelectorAll('.creator-socials img')].length===2&&[...document.querySelectorAll('.creator-socials img')].every(img=>img.src.startsWith('data:image/jpeg;base64,')&&img.naturalWidth>0&&img.width===avatar.width&&img.height===avatar.height)&&!document.querySelector('.creator-socials svg'),'social icons use embedded official color images at the same size as the portrait');
              assert(avatar.nextElementSibling.classList.contains('creator-socials')&&avatar.nextElementSibling.nextElementSibling.classList.contains('creator-info'),'official logos sit directly after the portrait, before copyright and email');
              assert(document.querySelector('.creator-youtube').getAttribute('href')==='https://www.youtube.com/@%E8%83%A1%E5%AD%90%E7%9B%96'&&document.querySelector('.creator-bilibili').getAttribute('href')==='https://space.bilibili.com/218610189','social buttons use verified account URLs');
              assert(document.querySelector('.creator-email').getAttribute('href')==='mailto:horffsky@gmail.com'&&document.querySelector('.copyright').textContent==='© 2026 胡子盖','copyright and clickable email are present');
              const glyphBounds=document.querySelector('.footer-icons').getBoundingClientRect(),creditBounds=document.querySelector('.creator-credit').getBoundingClientRect();
              assert(glyphBounds.right<creditBounds.left&&Math.abs(glyphBounds.top-creditBounds.top)<15,'desktop footer keeps decoration on the left and identity on the right');
              assert(footer.getBoundingClientRect().bottom<=innerHeight&&document.documentElement.scrollWidth<=innerWidth,'footer fits the window without horizontal overflow');

              assert(LH[0]==='FCPX'&&LH[1]==='SLIM'&&go.getAttribute('aria-label')==='加载','home starts with FCPX SLIM and Load');
              nativeEvent({type:'scan',payload:\(json)});
              assert(st==='ready'&&DATA.length===2,'real scan data populates event groups');
              assert(dropzone.style.display==='none','drop target is only shown on start page');
              assert(rs.getAttribute('aria-label')==='重新选择','restart clearly means choose another library');
              assert(!document.getElementById('empty').hidden&&!document.getElementById('empty').disabled&&document.getElementById('empty').getAttribute('aria-label')==='永久删除所选缓存','scan offers permanent deletion of current selection');
              assert(!document.getElementById('fcp').hidden&&document.getElementById('fcp').getAttribute('aria-label').includes('当前资源库'),'scan offers current library in FCP');
              assert(actionNotes.textContent.includes('移入废纸篓')&&actionNotes.textContent.includes('不可撤销')&&actionNotes.getBoundingClientRect().top>document.querySelector('.bar').getBoundingClientRect().bottom-4,'differences are explained below the buttons');
              nativeEvent({type:'openingFCP'});assert(go.disabled&&rs.disabled&&document.getElementById('empty').disabled&&document.getElementById('fcp').disabled,'FCP launch blocks conflicting actions');
              nativeEvent({type:'fcpOpenFailed',payload:'not installed'});assert(st==='ready'&&!go.disabled&&status.textContent==='not installed','FCP failure preserves scan and re-enables controls');
              assert(LH[0]==='可安全清理'&&meas(LH[0])+meas(LH[1])<=COLS-5,'safe-clean heading fits beside size');
              assert([...new Set('加载资源库撤销清理永久删除重新选择导入可安全清理取消扫描')].every(ch=>GLY[ch]),'all visible action glyphs exist in fixed font');
              recoveryAvailable=true;rs.click();assert(st==='idle'&&scanData===null&&sel.size===0&&recoveryAvailable,'restart returns to idle without discarding recovery');
              assert(document.querySelector('#empty').hidden&&!document.querySelector('#originalRelink'),'no standalone duplicate control on home');
              assert(!document.querySelector('.footer')&&!document.getElementById('hint')&&!document.getElementById('recover'),'bottom disclaimer and extra Restore Last Cleanup button are removed');
              assert([...document.querySelector('.bar-actions').children].slice(0,3).map(x=>x.id).join(',')==='go,empty,rs','primary actions appear in Clean Delete Choose order');
              const dupePayload={root:'/Project/Fixture.fcpbundle',total:10485760,candidates:[{id:'duplicate',event:'Event',category:'Duplicate Media',path:'/Project/Fixture.fcpbundle/Event/Original Media/take.mov',bytes:4194304,eligible:true,note:'Footage/take.mov',originalMatch:{privateBytes:0}}]};
              nativeEvent({type:'scan',payload:dupePayload});open_=true;ui();
              const byID=id=>document.getElementById(id);
              assert(!document.querySelector('#originalRelink')&&detail.textContent.includes('重复素材')&&detail.textContent.includes('0 B'),'duplicates appear in the existing details with a separate disk estimate');
              assert(byID('duplicate-toggle-0').getAttribute('aria-expanded')==='false'&&byID('duplicate-toggle-0').textContent.includes('/Project')&&byID('duplicate-toggle-0').textContent.includes('4.0MB'),'collapsed group shows its total and comparison folder');
              assert(byID('duplicate-items-0').hidden&&byID('duplicate-items-0').childElementCount===0,'collapsed group does not render file rows');
              assert(byID('duplicate-select-0').getAttribute('aria-checked')==='true'&&selectedIDs().includes('duplicate'),'duplicate media are selected by default');
              byID('duplicate-toggle-0').click();
              const duplicateRow=byID('duplicate-items-0').querySelector('[role="checkbox"]');
              assert(duplicateRow.textContent.includes('take.mov')&&duplicateRow.textContent.includes('Footage/take.mov'),'expanding shows the individual name and link path');
              duplicateRow.click();
              assert(selectedIDs().length===0&&go.disabled&&byID('duplicate-items-0').querySelector('[role="checkbox"]').getAttribute('aria-checked')==='false','unchecking duplicate media excludes it from cleanup');
              assert(byID('duplicate-toggle-0').getAttribute('aria-expanded')==='true'&&byID('duplicate-select-0').getAttribute('aria-checked')==='false','individual selection leaves the chosen group open');
              byID('duplicate-toggle-0').click();byID('duplicate-select-0').click();
              assert(selectedIDs().length===1&&byID('duplicate-items-0').hidden,'group can be selected without expanding it');
              const large={...dupePayload,candidates:Array.from({length:1000},(_,i)=>({...dupePayload.candidates[0],id:'file'+i,event:'Event'+(i%8),path:'/Project/Fixture.fcpbundle/Event'+(i%8)+'/Original Media/file'+i+'.mov',bytes:1048576,note:'Footage/file'+i+'.mov'}))};
              nativeEvent({type:'scan',payload:large});
              assert(duplicateGroups.size===1&&byID('duplicate-items-0').childElementCount===0&&selectedIDs().length===1000,'a thousand duplicates across events stay in one collapsed group');
              byID('duplicate-toggle-0').click();
              const expandedList=byID('duplicate-items-0');expandedList.scrollTop=1200;expandedList.dispatchEvent(new Event('scroll'));
              assert(expandedList.childElementCount===1000&&expandedList.scrollHeight>expandedList.clientHeight,'expanded file rows scroll inside the detail group');
              expandedList.children[45].click();
              assert(byID('duplicate-items-0').scrollTop===1200&&byID('duplicate-select-0').getAttribute('aria-checked')==='mixed'&&selectedIDs().length===999,'individual selection preserves the scroll position and displays mixed selection');
              byID('duplicate-toggle-0').click();
              assert(byID('duplicate-items-0').childElementCount===0&&selectedIDs().length===999,'collapsing removes the rendered rows and keeps the selection');
              nativeEvent({type:'scan',payload:dupePayload});
              nativeEvent({type:'permanentReview',payload:{items:['Event / 重复素材 / take.mov'],size:'4 MB',estimatedDisk:'0 B',hasDuplicates:true}});
              assert(sheetFiles.textContent.includes('4 MB')&&sheetFiles.textContent.includes('0 B')&&sheetText.textContent.includes('无法撤销')&&document.activeElement===sheetCancel,'duplicate permanent delete uses the existing confirmation');
              closeSheet(true);rs.click();
              assert(dropzone.style.display==='flex'&&getComputedStyle(dropzone).borderStyle==='dashed','dashed library drop target is visible');
              const icon=document.getElementById('dropIcon'),pixels=icon.getContext('2d').getImageData(0,0,icon.width,icon.height).data;
              const whiteDots=(cx,cy)=>{let count=0;for(let y=cy-27;y<cy+27;y++)for(let x=cx-27;x<cx+27;x++){const i=(y*icon.width+x)*4;if(pixels[i]>245&&pixels[i+1]>245&&pixels[i+2]>245&&pixels[i+3]>220)count++}return count};
              assert(icon.width===216&&icon.height===240&&[41,64].every(y=>[24,48].every(x=>whiteDots(x*3,y*3)>200)),'square library icon has four legible white stars');
              assert(dropTitle.querySelector('canvas')&&dropTitle.textContent===''&&!document.getElementById('dropHint')&&status.textContent==='','drop instruction uses dotted glyphs without redundant hints');
              assert(getComputedStyle(go).borderRadius==='11px'&&getComputedStyle(go).borderColor==='rgba(0, 0, 0, 0)','actions have rounded corners without solid borders');
              assert(getComputedStyle(go).boxShadow!=='none'&&getComputedStyle(go).transitionDuration!=='0s','action buttons float and respond to hover');
              assert(document.getElementById('settings').previousElementSibling===snd,'gear settings follows sound toggle');
              assert(getComputedStyle(document.getElementById('settingsLabel')).boxShadow==='none'&&getComputedStyle(document.getElementById('settingsLabel')).backgroundImage==='none','gear has no raised square background');
              nativeEvent({type:'showSettings'});assert(document.getElementById('settings').open&&document.activeElement.id==='settingsLabel','Tools menu opens gear settings');
              document.querySelector('.prefs').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));assert(settings.open,'settings stays open while choosing an option');
              document.body.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));assert(!settings.open,'clicking outside closes settings');
              nativeEvent({type:'showSettings'});document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert(!settings.open&&document.activeElement.id==='settingsLabel','Escape closes settings and restores gear focus');
              dropzone.click();assert(sheetMode==='choose'&&!veil.hidden&&sheetBrowser.hidden===false&&sheetPath.hidden&&!sheetAccept.hidden&&sheetAccept.disabled,'drop target opens Finder style folder and library chooser');closeSheet();
              nativeEvent({type:'showSettings'});go.click();assert(sheetMode==='choose'&&!document.getElementById('settings').open,'Load closes settings before opening browser');closeSheet();
              openSheet('choose');nativeEvent({type:'browseResult',payload:{path:'/Users/test/video 999',name:'video 999',places:[{name:'桌面',path:'/Users/test/Desktop'},{name:'文稿',path:'/Users/test/Documents'},{name:'下载',path:'/Users/test/Downloads'},{name:'External SSD',path:'/Volumes/External SSD',volume:true}],crumbs:[{name:'Macintosh HD',path:'/'},{name:'video 999',path:'/Users/test/video 999'}],items:[{name:'Subfolder',path:'/Users/test/video 999/Subfolder',folder:true},{name:'Sample.fcpbundle',path:'/Users/test/video 999/Sample.fcpbundle',library:true},{name:'camera.mov',path:'/Users/test/video 999/camera.mov',folder:false,library:false}]}});
              assert(browserPlaces.querySelectorAll('button').length===4&&browserPlaces.textContent.includes('External SSD'),'sidebar shows user folders and connected external volumes');
              assert(placeName({name:'Desktop'})==='桌面'&&placeName({name:'Documents'})==='文稿'&&placeName({name:'Downloads'})==='下载','standard user folders are labeled in Chinese in the Chinese interface');
              assert(!document.getElementById('browserHome')&&!document.getElementById('browserUp')&&!document.getElementById('browserBack')&&!document.getElementById('browserVolumes'),'obsolete navigation buttons are removed');
              assert(browserItems.querySelectorAll('button').length===3&&browserCurrent.textContent==='video 999'&&browserItems.querySelectorAll('button:disabled').length===1,'right pane shows folders libraries and unavailable ordinary files');
              assert(browserPath.querySelectorAll('button').length===2&&!sheetAccept.disabled,'breadcrumb path and Open allow selecting the current enclosing folder');
              browserItems.querySelectorAll('button')[0].click();assert(browserSelected.folder&&sheetMode==='choose','single click selects a folder without opening or scanning it');
              browserItems.querySelectorAll('button')[1].click();assert(sheetMode==='choose'&&browserSelected.library&&browserSelection.textContent==='Sample.fcpbundle','library selection waits for Open or double click');
              browserItems.querySelectorAll('button')[1].dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));assert(veil.hidden,'double clicking a library accepts it');
              nativeEvent({type:'loaded',payload:{name:'Sample.fcpbundle',path:'/tmp/Sample.fcpbundle'}});assert(st==='scan'&&go.disabled&&status.textContent.includes('Sample.fcpbundle'),'loading or dropping a library immediately starts scanning without a second button');
              assert(labs.every(c=>c.isConnected),'auto scan retains connected dotted labels');
              nativeEvent({type:'scan',payload:\(json)});renderFrame(T0+300);const fastFirst=scanVisual;renderFrame(T0+650);
              assert(st==='scan'&&scanVisual>fastFirst&&scanVisual<1,'fast completed scan still has a short smooth visual progression');
              renderFrame(T0+SCAN_PRESENT_MS+1);assert(st==='ready'&&pendingScanResult===null,'fast scan settles into real results after the short transition');
              nativeEvent({type:'loaded',payload:{name:'纪实摄影_春日计划_龘𠮷.fcpbundle'}});
              assert(st==='scan'&&status.textContent.includes('纪实摄影_春日计划_龘𠮷.fcpbundle'),'auto scanning keeps arbitrary Chinese library names readable');
              nativeEvent({type:'librariesFound',payload:{items:[{name:'One.fcpbundle',path:'/video 999/A/One.fcpbundle',library:true},{name:'Two.fcpbundle',path:'/video 999/B/Two.fcpbundle',library:true}],unreadable:0}});
              assert(sheetMode==='libraries'&&sheetAccept.disabled&&browserItems.querySelectorAll('[role="checkbox"]').length===2,'multiple discovered libraries prompt for selection instead of auto choosing one');
              browserItems.querySelectorAll('button')[0].click();browserItems.querySelectorAll('button')[1].click();
              assert(libraryChoices.size===2&&!sheetAccept.disabled&&browserItems.querySelectorAll('[aria-checked="true"]').length===2,'multiple libraries can be selected together');
              assert(browserItems.textContent.includes('/video 999/A/One.fcpbundle'),'discovered libraries show full paths to distinguish equal names');
              sheetAccept.click();assert(veil.hidden,'selected libraries proceed with one confirmation');
              nativeEvent({type:'unsupported',payload:'Only .fcpbundle'});assert(sheetMode==='unsupported'&&sheetTitle.textContent==='不支持此文件','unsupported files show a branded prompt');closeSheet();
              nativeEvent({type:'scan',payload:\(json)});
              nativeEvent({type:'cleanReview',payload:{items:['Interview / Render Files'],size:'180 MB'}});
              assert(sheetMode==='clean'&&sheetFiles.textContent.includes('Render Files')&&!veil.hidden,'clean review lists exact candidate before action');closeSheet();
              nativeEvent({type:'permanentReview',payload:{items:['Interview / Render Files'],size:'180 MB'}});
              assert(sheetMode==='permanent'&&sheetText.textContent.includes('无法恢复')&&sheetFiles.textContent.includes('180 MB')&&document.activeElement===sheetCancel,'direct permanent delete reviews exact items and size with Cancel focused');closeSheet();
              nativeEvent({type:'emptyReview',payload:{items:['Interview / Render Files'],size:'180 MB'}});
              assert(sheetMode==='empty'&&sheetText.textContent.includes('无法恢复')&&document.activeElement===sheetCancel,'permanent delete review explains irreversibility and defaults to cancel');closeSheet();
              nativeEvent({type:'emptyReview',payload:{items:['/Users/test/.Trash/Render Files'],size:'12 MB',refreshedLegacy:true}});assert(sheetText.textContent.includes('旧版校验未通过')&&sheetFiles.textContent.includes('/Users/test/.Trash/Render Files')&&document.activeElement===sheetCancel,'legacy retry explicitly reviews actual Trash paths and size with cancel focused');closeSheet();
              open_=true;ui();
              assert(document.querySelectorAll('.row:not(.lock)').length===2,'only eligible rows selectable');
              assert(!detail.querySelector('b'),'event names rendered as text, not HTML');
              const oldSel=sel.size;document.querySelector('.row:not(.lock)').click();
              assert(sel.size===oldSel-1,'row selection updates real candidates');selAll();enter('ready');
              const originalBin=drawBin;let binCalls=0;drawBin=(...args)=>{binCalls++;return originalBin(...args)};
              nativeEvent({type:'scan',payload:{root:'/empty.fcpbundle',total:1048576,candidates:[]}});renderFrame(T0+16);
              assert(nothingToClean()&&binCalls===0&&cv.getAttribute('aria-label').includes('你已经够瘦啦！'),'no removable caches replaces bin with already-slim message');
              assert([...'你已经够瘦啦！'].every(ch=>GLY[ch]&&GLY[ch].slice(1).some(Boolean)),'already-slim message has all approved Chinese glyphs');
              assert(go.disabled&&document.getElementById('empty').disabled&&!document.getElementById('fcp').disabled,'nothing-to-clean result keeps FCP usable and destructive actions disabled');
              nativeEvent({type:'scan',payload:{root:'/retained.fcpbundle',total:4096,candidates:[{event:'Analysis',category:'Analysis Files',bytes:4096,id:'analysis-only',eligible:false,note:'Retained'}]}});renderFrame(T0+16);
              assert(nothingToClean()&&binCalls===0,'retained-only caches also show no cleanup is needed');
              nativeEvent({type:'scan',payload:\(json)});sel.clear();enter('ready');renderFrame(T0+16);
              assert(!nothingToClean()&&binCalls>0&&!cv.getAttribute('aria-label').includes('你已经够瘦啦！'),'unchecking all candidates never falsely claims the library is already slim');
              drawBin=originalBin;selAll();enter('ready');
              assert(GH===13&&GLY===GLYS.d,'Dotted Songti Square is the fixed font');
              assert(!document.querySelector('#font'),'font selector removed');
              assert([...document.querySelectorAll('.prefs select')].every(x=>x.hidden)&&document.querySelectorAll('.choices button').length===5&&!document.querySelector('[data-target="layout"]')&&lay==='A','settings keep one fixed animation and dotted theme controls');
              theme.value='light';theme.dispatchEvent(new Event('change'));
              assert(getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()==='#F6F1E7'&&getComputedStyle(document.documentElement).getPropertyValue('--grid').trim()==='#E4DFD5','warm paper and pale gray light grid');
              const lightSurface=getComputedStyle(go).backgroundImage,lightShadow=getComputedStyle(go).boxShadow;
              assert(lightSurface.includes('radial-gradient')&&lightSurface.includes('linear-gradient')&&lightShadow.includes('inset'),'light buttons show dotted gradient and raised edge');
              const lightButtonColors=['--btn-top','--btn-bottom','--btn-dot','--btn-shadow'].map(name=>getComputedStyle(document.documentElement).getPropertyValue(name).trim());
              theme.value='dark';theme.dispatchEvent(new Event('change'));
              assert(getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()==='#111113'&&getComputedStyle(document.documentElement).getPropertyValue('--grid').trim()==='#29292D','dark appearance and subdued grid');
              assert(['--btn-top','--btn-bottom','--btn-dot','--btn-shadow'].some((name,i)=>getComputedStyle(document.documentElement).getPropertyValue(name).trim()!==lightButtonColors[i])&&getComputedStyle(go).boxShadow.includes('inset'),'dark buttons retain distinct dotted depth');
              lng.value='en';lng.dispatchEvent(new Event('change'));
              assert(go.getAttribute('aria-label')==='Move selected caches to Trash','English controls');
              lng.value='zh';lng.dispatchEvent(new Event('change'));
              theme.value='light';theme.dispatchEvent(new Event('change'));
              const luminance=hex=>{const c=hex.replace('#','').match(/../g).map(c=>parseInt(c,16)/255).map(c=>c<=.04045?c/12.92:((c+.055)/1.055)**2.4);return c[0]*.2126+c[1]*.7152+c[2]*.0722};
              const bg=luminance('#F6F1E7'),textInk=luminance('#171717');
              assert((bg+.05)/(textInk+.05)>7,'light text contrast exceeds 7 to 1');
              assert(getComputedStyle(document.documentElement).getPropertyValue('--acc').trim()==='#FF7A1A','bright orange stays bright in light mode');
              assert([...'已扫描'].every(ch=>GLY[ch]&&GLY[ch].slice(1).some(Boolean)),'scanned label has all approved Chinese glyphs');
              nativeEvent({type:'scanning',payload:'fixture'});
              nativeEvent({type:'scanWork',payload:{fraction:.14,comparing:true}});renderFrame(scanWorkStart+SCAN_TRACK_MS);
              const revealed=()=>Array.from(mk).filter((v,i)=>v&&bs[i]).length,totalScanInk=Array.from(mk).filter(Boolean).length,firstScanInk=revealed();
              assert(firstScanInk>0&&firstScanInk<totalScanInk,'scanned letters emerge partially with the growing bar');
              assert(Array.from(t).every((v,i)=>!isB[i]||bs[i]||v===0),'unfilled progress area never shows ghost letters');
              nativeEvent({type:'scanWork',payload:{fraction:.32,comparing:true}});renderFrame(scanWorkStart+SCAN_TRACK_MS);assert(revealed()>firstScanInk,'more scanned letters emerge as the progress bar advances');
              nativeEvent({type:'scan',payload:\(json)});renderFrame(T0+SCAN_PRESENT_MS+1000);
              assert(st==='ready'&&revealed()===totalScanInk&&totalScanInk>0,'scanned label is fully revealed after actual scan completion');
              const zhScanInk=Array.from(mk).join('');lng.value='en';lng.dispatchEvent(new Event('change'));assert(Array.from(mk).join('')!==zhScanInk,'scanned label follows English language setting');lng.value='zh';lng.dispatchEvent(new Event('change'));assert(Array.from(mk).join('')===zhScanInk,'Chinese scanned label returns with language setting');
              nativeEvent({type:'scanning',payload:'fixture'});renderFrame(T0+500);const scan1=scanVisual;renderFrame(T0+1200);
              assert(scanVisual>scan1&&scanVisual<1,'scan grows without pretending traversal is complete');
              assert(MAGNIFIER.length===12,'scan retains moving magnifier');
              scanVisual=.9;const magA=magnifierPose(T0),magB=magnifierPose(T0+500);assert(Math.abs(magA.x-magB.x)>.2&&Math.abs(magA.y-magB.y)>.3&&Math.abs(magA.angle-magB.angle)>.03,'magnifier keeps drifting and rotating even when scan progress holds still');
              const reducedA=magnifierPose(T0+100,true),reducedB=magnifierPose(T0+650,true);assert(JSON.stringify(reducedA)===JSON.stringify(reducedB),'reduced motion keeps magnifier steady');
              renderFrame(T0+30000);assert(st==='scan'&&scanVisual<1&&pendingScanResult===null,'slow scans never show completion before actual native results arrive');
              enter('scan');renderFrame(T0+15000);
              assert(scanVisual<.1,'unmeasured traversal leaves the bar near the start');
              const stages=[.16,.40,.64,.88],measured=[];
              for(const fraction of stages){
                nativeEvent({type:'scanWork',payload:{fraction,comparing:true}});
                renderFrame(scanWorkStart+SCAN_TRACK_MS/2);const half=scanVisual;
                renderFrame(scanWorkStart+SCAN_TRACK_MS);
                assert(Math.abs(half-(scanWorkFrom+scanWorkTo)/2)<.001,'comparison interpolates linearly between progress samples');
                measured.push(scanVisual);
              }
              assert(measured.every((value,i)=>i===0||value>measured[i-1])&&measured[3]>.8&&st==='scan'&&status.textContent.includes('比对重复素材'),'progress continues through the late duplicate comparison');
              nativeEvent({type:'scanWork',payload:{fraction:1,comparing:true}});renderFrame(scanWorkStart+SCAN_TRACK_MS);
              assert(scanVisual<1&&st==='scan','real read progress waits for the native scan result before filling');
              assert(MEDIA_ICONS.length===7&&gravityNodes.length===7,'seven approved icons installed');
              const video=MEDIA_ICONS[0].dots,clapper=MEDIA_ICONS[3].dots;
              assert(video.some(([x,y,c])=>x===15&&y===12&&c==='acc'),'play triangle retains complete apex');
              assert(['black','white'].every(c=>clapper.some(d=>d[2]===c)),'clapper keeps black and white zebra bands');
              const burst=SPACE_SEEDS.map((s,i)=>gravityPose(i,760,0)),bin=binGeometry();
              assert(burst.every(p=>p.alpha===1&&!p.captured)&&burst.some(p=>p.x<bin.center)&&burst.some(p=>p.x>bin.center)&&burst.some(p=>p.y<bin.mouth)&&burst.some(p=>p.y>bin.mouth),'all icons burst simultaneously across both sides and depths');
              assert(Math.max(...burst.map(p=>p.scale))/Math.min(...burst.map(p=>p.scale))>2&&Math.max(...burst.map(p=>p.blur))>6,'foreground expands and defocuses more than background');
              const focus=gravityPose(0,1800,SPACE_SEEDS[0].start+SPACE_SEEDS[0].duration*.94);
              assert(focus.scale<burst[0].scale&&focus.blur<burst[0].blur*.15,'suction shrinks and progressively focuses icons');
              assert(suctionCurve(.95)-suctionCurve(.85)>4*(suctionCurve(.35)-suctionCurve(.25)),'suction accelerates sharply instead of moving linearly');
              let topOnly=true,monotone=true,previous=0;
              for(let n=0;n<=500;n++){
                const progress=n/500,mass=absorbedMass(progress);monotone=monotone&&mass>=previous;previous=mass;
                SPACE_SEEDS.forEach((s,i)=>{const p=gravityPose(i,3000,progress);if(p.captured){topOnly=topOnly&&p.x===bin.center&&p.scale*12<BIN_HALF}});
              }
              assert(topOnly,'all seven paths align above mouth before vertical capture');
              assert(monotone&&absorbedMass(0)===0&&absorbedMass(1)===1,'bin starts empty and grains accumulate to full');
              assert(GRAINS.length>100&&BODY_DOTS.slice(1).every((p,i)=>Math.hypot(p[0]-BODY_DOTS[i][0],p[1]-BODY_DOTS[i][1])<.9),'packed grains use existing smooth tapered bin');
              nativeEvent({type:'cleaning'});realProgress=.2;renderFrame(T0+200);
              assert(visualProgress===0&&!gravity.hidden,'camera burst precedes measured suction');
              renderFrame(T0+416);assert(visualProgress>0&&CLEAN_BURST_MS===400,'suction starts immediately after short burst without fixed hold');
              for(let i=1;i<=200;i++)renderFrame(T0+416+i*16);
              assert(visualProgress<=.2&&st==='clean','suction and fill wait at real progress when file operation stalls');
              const posesA=SPACE_SEEDS.map((s,i)=>gravityPose(i,4000,visualProgress).u);
              renderFrame(T0+6000);
              assert(SPACE_SEEDS.every((s,i)=>gravityPose(i,6000,visualProgress).u===posesA[i]),'waiting does not replay or consume extra icons');
              nativeEvent({type:'error',payload:'preview interruption'});
              assert(gravity.hidden,'error immediately removes foreground overlay');closeSheet();
              nativeEvent({type:'scan',payload:\(json)});
              nativeEvent({type:'cleaning'});nativeEvent({type:'cleanProgress',payload:{done:1,total:2}});
              for(let i=1;i<=200;i++)renderFrame(T0+i*16);
              assert(st==='clean','animation cannot finish ahead of real operation');
              assert(!soundEvents.includes('done'),'completion sound waits for native completion');
              nativeEvent({type:'cleanProgress',payload:{done:1,total:1}});
              for(let i=201;i<=300;i++)renderFrame(T0+i*16);
              assert(st==='clean'&&visualProgress<=.94&&absorbedMass(visualProgress)<1&&SPACE_SEEDS.some((s,i)=>gravityPose(i,5000,visualProgress).u<1),'last icon and unfinished bin remain until native completion even after 100 percent progress');

              nativeEvent({type:'cleaned'});for(let i=301;i<=355;i++)renderFrame(T0+i*16);
              assert(st==='done'&&realProgress===1&&gravity.hidden&&binFill()===1,'completed operation reaches result with full bin and no foreground');
              assert(go.getAttribute('aria-label')==='撤销清理'&&actionNotes.textContent.includes('本次'),'cleanup result offers undo with current-batch explanation');
              assert(!document.getElementById('trash'),'cleanup result has no Open Trash button');
              const main=document.querySelector('main'),oldMax=main.style.maxWidth;main.style.maxWidth='500px';
              assert(Math.abs(settings.getBoundingClientRect().top-go.getBoundingClientRect().top)<2&&Math.abs(settings.getBoundingClientRect().top-snd.getBoundingClientRect().top)<2,'sound and settings stay on the first row when actions wrap');
              main.style.maxWidth=oldMax;
              nativeEvent({type:'scan',payload:\(json)});nativeEvent({type:'cleaning'});nativeEvent({type:'cleaned'});
              for(let i=1;i<=75;i++)renderFrame(T0+i*16);
              assert(st==='done','fast real cleanup finishes animation within 1.2 seconds instead of fixed 4.8 seconds');
              assert(soundEvents.includes('burst')&&soundEvents.includes('suction')&&!soundEvents.includes('empty'),'burst and moving suction have separate sound triggers and cleanup does not play empty sound');

              assert(soundEvents.includes('done'),'selected completion sound plays when cleanup actually completes');
              assert(!document.querySelector('#empty').hidden&&currentCanEmpty,'empty action appears only for a completed cleanup');
              nativeEvent({type:'emptying'});assert(go.disabled&&rs.disabled,'permanent deletion blocks conflicting actions');
              assert(soundEvents.filter(s=>s==='empty').length===1,'trash sound plays when confirmed emptying starts');
              const audioBefore=AC;nativeEvent({type:'emptied',payload:1024});
              renderFrame(T0+16);assert(st==='emptying'&&binFill()>.9&&go.disabled,'fast native deletion waits for the slower emptying visual');
              for(let i=2;i<=38;i++)renderFrame(T0+i*16);const halfEmpty=binFill();assert(st==='emptying'&&halfEmpty>.3&&halfEmpty<.7,'emptying gradually removes bin contents around the midpoint');
              for(let i=39;i<=80;i++)renderFrame(T0+i*16);
              assert(st==='emptied'&&!currentCanEmpty&&document.querySelector('#empty').hidden,'permanent deletion removes recovery and empty controls for this batch');
              assert(dropzone.style.display==='none'&&LH[0]==='已节省硬盘空间'&&go.getAttribute('aria-label')==='加载','completed emptying keeps the result unobstructed and Load available');
              assert([...'已节省硬盘空间'].every(ch=>GLY[ch]&&GLY[ch].slice(1).some(v=>v)),'savings headline has complete glyphs in the approved dotted font');
              assert(LH[1]===fmt(1024/1048576),'saved capacity comes from actual native deletion bytes rather than a stale scan selection');
              head('已节省硬盘空间','374.0MB');const orangeCols=[],whiteCols=[];for(let r=0;r<16;r++)for(let c=0;c<COLS;c++)if(t[I(c,r)]===1)(kd[I(c,r)]?orangeCols:whiteCols).push(c);assert(Math.max(...orangeCols)+1<Math.min(...whiteCols),'long savings headline fits beside the capacity without overlapping');
              assert(AC===audioBefore,'muted empty sound does not start audio');
              assert(soundEvents.filter(s=>s==='empty').length===1,'empty completion does not replay the trash sound');
              nativeEvent({type:'scan',payload:\(json)});const directSounds=soundEvents.length;nativeEvent({type:'deleting'});const directStart=T0;
              assert(st==='clean'&&go.disabled&&document.getElementById('fcp').disabled&&status.textContent.includes('第 1 步'),'direct deletion starts with cleanup animation and locks conflicting controls');
              nativeEvent({type:'cleanProgress',payload:{done:1,total:2}});for(let i=1;i<=70;i++)renderFrame(directStart+i*16);
              assert(st==='clean'&&visualProgress<=.5&&!soundEvents.slice(directSounds).includes('empty'),'first animation follows real movement without prematurely emptying the bin');
              nativeEvent({type:'permanentMoved'});for(let i=71;i<=160&&st==='clean';i++)renderFrame(directStart+i*16);
              assert(st==='emptying'&&binFill()===1&&status.textContent.includes('第 2 步')&&go.disabled,'completed cleanup leads directly to a full-bin emptying animation without an undo screen');
              const directEmptyStart=T0;for(let i=1;i<=35;i++)renderFrame(directEmptyStart+i*16);
              assert(st==='emptying'&&binFill()>0&&binFill()<1,'second animation visibly empties the filled bin');
              nativeEvent({type:'emptied',payload:8192});for(let i=36;i<=100;i++)renderFrame(directEmptyStart+i*16);
              assert(st==='emptied'&&!currentCanEmpty&&LH[1]===fmt(8192/1048576),'both direct-deletion animations finish with actual bytes and no undo');
              assert(soundEvents.slice(directSounds).join(',').startsWith('burst')&&soundEvents.slice(directSounds).filter(x=>x==='empty').length===1,'combined operation plays cleanup then empty sound exactly once');
              nativeEvent({type:'scan',payload:\(json)});nativeEvent({type:'deleting'});const fastDirectStart=T0;nativeEvent({type:'permanentMoved'});nativeEvent({type:'emptied',payload:16384});
              assert(st==='clean'&&permanentResult===16384,'fast native deletion is buffered while cleanup animation remains visible');
              for(let i=1;i<=100&&st==='clean';i++)renderFrame(fastDirectStart+i*16);
              assert(st==='emptying'&&emptyBytes===16384&&emptyNativeDone&&binFill()===1,'fast operation still presents the full second animation');
              const fastEmptyStart=T0;renderFrame(fastEmptyStart+16);assert(st==='emptying'&&binFill()>.9,'fast operation never skips straight to the result');
              for(let i=2;i<=100;i++)renderFrame(fastEmptyStart+i*16);assert(st==='emptied'&&!permanentRun&&LH[1]===fmt(16384/1048576),'fast two-step animation completes with the buffered real result');
              nativeEvent({type:'emptying'});for(let i=1;i<=150;i++)renderFrame(T0+i*16);assert(st==='emptying'&&binFill()>0&&go.disabled,'slow deletion cannot visually finish before actual native completion');
              nativeEvent({type:'emptied',payload:1024});for(let i=151;i<=165;i++)renderFrame(T0+i*16);assert(st==='emptied'&&binFill()===0,'slow deletion finishes the remaining visual after native success');

              nativeEvent({type:'restoring'});nativeEvent({type:'restoreProgress',payload:{done:1,total:1}});renderFrame(T0+600);
              assert(st==='back','restore relighting state');
              nativeEvent({type:'error',payload:'test failure'});
              assert(status.textContent==='test failure'&&st==='idle','explicit failure state');
              assert(document.querySelector('meta[http-equiv="Content-Security-Policy"]').content.includes("connect-src 'none'"),'network blocked by policy');
              nativeEvent({type:'scan',payload:\(json)});nativeEvent({type:'cleaning'});realProgress=.5;
              const times=[];for(let i=1;i<=150;i++){const at=performance.now();renderFrame(T0+i*16);times.push(performance.now()-at)}
              times.sort((a,b)=>a-b);const perf='Render CPU: median '+times[75].toFixed(2)+'ms, p95 '+times[142].toFixed(2)+'ms';
              return checks.join('\\n')+'\\n'+checks.length+' web checks passed\\n'+perf;

            })()
            """
            web.evaluateJavaScript(script) { result, error in
                if let error = error { print("FAIL \(error)"); exit(1) }
                print(result as? String ?? "FAIL missing result"); exit(result is String ? 0 : 1)
            }
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
@main struct RunWebTests {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let tests = WebTests(); app.delegate = tests
        withExtendedLifetime(tests) { app.run() }
    }
}
