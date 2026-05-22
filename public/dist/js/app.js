(function(){
  'use strict';

  const $=id=>document.getElementById(id);
  const API_BASE='http://127.0.0.1:17071';

  let state={
    songs:[],
    searchResults:[],
    searchKeyword:'',
    currentPage:1,
    searchTotal:0,
    highQuality:true,
    selectedMids:[],
    savePath:localStorage.getItem('qqmusic_save_path')||'',
    recentDirs:JSON.parse(localStorage.getItem('qqmusic_recent_dirs')||'[]'),
    pageScrolls:{},
    searchSource:localStorage.getItem('search_source')||'qq',
    isPlaylistPage:false,
    isSearching:false,
    shufflePlaylist:[],
    shuffleIndex:-1,
    playHistory:[],
    historyIndex:-1,
    currentLyricMid:null,
    currentLyricRaw:'',
    currentLyricParsed:null
  };

  let currentLyricCloseHandler=null;
  let currentLyricClickHandler=null;
  let lyricAutoFollow=true;
  let lyricScrollTimer=null;
  let isProgrammaticScroll=false;
  let lyricScrollDelegated=false;
  let lyricRafId=null;

  const TINY_COVER='data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  let playlistImageObserver=null;
  function ensurePlaylistImageObserver(){
    if(playlistImageObserver) return;
    playlistImageObserver=new IntersectionObserver((entries)=>{
      entries.forEach(entry=>{
        const img=entry.target;
        if(entry.isIntersecting){
          if(img.dataset.src&&img.src!==img.dataset.src){
            img.src=img.dataset.src;
          }
        } else {
          if(img.dataset.src&&img.src===img.dataset.src){
            img.src=TINY_COVER;
          }
        }
      });
    },{rootMargin:'1000px 0px'});
  }

  function saveShuffleState(){
    try{
      localStorage.setItem('shuffle_playlist',JSON.stringify(state.shufflePlaylist));
      localStorage.setItem('shuffle_index',String(state.shuffleIndex));
    }catch(e){}
  }

  function loadShuffleState(){
    try{
      const pl=JSON.parse(localStorage.getItem('shuffle_playlist')||'[]');
      const idx=parseInt(localStorage.getItem('shuffle_index')||'-1');
      if(Array.isArray(pl)&&pl.length>0&&idx>=0&&idx<pl.length){
        state.shufflePlaylist=pl;
        state.shuffleIndex=idx;
      }
    }catch(e){}
  }

  function savePlayHistory(){
    try{
      localStorage.setItem('play_history',JSON.stringify(state.playHistory));
      localStorage.setItem('history_index',String(state.historyIndex));
    }catch(e){}
  }

  function loadPlayHistory(){
    try{
      const h=JSON.parse(localStorage.getItem('play_history')||'[]');
      const idx=parseInt(localStorage.getItem('history_index')||'-1');
      if(Array.isArray(h)){
        state.playHistory=h;
        state.historyIndex=idx;
      }
    }catch(e){}
  }

  function pushHistory(mid){
    if(state.historyIndex>=0){
      state.playHistory=state.playHistory.slice(0,state.historyIndex+1);
    }
    const existIdx=state.playHistory.indexOf(mid);
    if(existIdx>=0) state.playHistory.splice(existIdx,1);
    state.playHistory.push(mid);
    if(state.playHistory.length>200) state.playHistory.shift();
    state.historyIndex=-1;
    savePlayHistory();
  }

  function buildShufflePlaylist(startMid){
    const mids=state.songs.map(s=>s.mid);
    for(let i=mids.length-1;i>0;i--){
      const j=Math.floor(Math.random()*(i+1));
      [mids[i],mids[j]]=[mids[j],mids[i]];
    }
    if(startMid&&mids.length>1&&mids[0]===startMid){
      [mids[0],mids[1]]=[mids[1],mids[0]];
    }
    state.shufflePlaylist=mids;
    state.shuffleIndex=0;
    state.playHistory=[];
    state.historyIndex=-1;
    saveShuffleState();
    savePlayHistory();
  }

  function getNextShuffleSong(){
    if(state.songs.length===0) return null;
    if(state.historyIndex>=0&&state.historyIndex<state.playHistory.length-1){
      state.historyIndex++;
      savePlayHistory();
      const mid=state.playHistory[state.historyIndex];
      return state.songs.find(s=>s.mid===mid)||null;
    }
    if(state.shufflePlaylist.length===0||state.shufflePlaylist.length!==state.songs.length){
      buildShufflePlaylist(Player.currentSong?.mid);
    }
    state.shuffleIndex++;
    if(state.shuffleIndex>=state.shufflePlaylist.length){
      buildShufflePlaylist(Player.currentSong?.mid);
    }
    saveShuffleState();
    const mid=state.shufflePlaylist[state.shuffleIndex];
    const song=state.songs.find(s=>s.mid===mid);
    if(!song){
      buildShufflePlaylist(Player.currentSong?.mid);
      return state.songs.find(s=>s.mid===state.shufflePlaylist[0])||null;
    }
    return song;
  }

  function reshuffleAndPlayFromEnd(){
    buildShufflePlaylist(Player.currentSong?.mid);
    if(state.shufflePlaylist.length===0) return null;
    state.shuffleIndex=state.shufflePlaylist.length-1;
    state.playHistory=[...state.shufflePlaylist];
    state.historyIndex=state.shufflePlaylist.length-1;
    saveShuffleState();
    savePlayHistory();
    return state.songs.find(s=>s.mid===state.shufflePlaylist[state.shuffleIndex])||null;
  }

  function getPrevShuffleSong(){
    if(state.songs.length===0) return null;
    if(state.playHistory.length===0){
      return reshuffleAndPlayFromEnd();
    }
    if(state.historyIndex===-1){
      if(state.playHistory.length<2){
        return reshuffleAndPlayFromEnd();
      }
      state.historyIndex=state.playHistory.length-2;
    } else if(state.historyIndex>0){
      state.historyIndex--;
    } else {
      return reshuffleAndPlayFromEnd();
    }
    savePlayHistory();
    const mid=state.playHistory[state.historyIndex];
    return state.songs.find(s=>s.mid===mid)||null;
  }

  const DOWNLOAD_ICON='<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>';
  const DOWNLOAD_ICON_SM='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>';
  const SOURCE_QQ_ICON='<span class="source-icon source-qq" title="QQ音乐"><img src="https://y.qq.com/favicon.ico" alt="QQ" onerror="this.parentNode.innerHTML=\'Q\'"></span>';
  const SOURCE_NETEASE_ICON='<span class="source-icon source-netease" title="网易云音乐"><img src="https://music.163.com/favicon.ico" alt="网易" onerror="this.parentNode.innerHTML=\'N\'"></span>';
  const R=10,C=2*Math.PI*R;

  function setDlRing(mid,pct,status){
    const el=document.querySelector('[data-dl-mid="'+mid+'"]');
    if(!el) return;
    if(status==='done'){
      el.outerHTML=makeDlBtn(mid);
    } else if(status==='fail'){
      el.innerHTML='<span class="song-progress-fail">✗</span>';
      setTimeout(()=>{el.innerHTML=DOWNLOAD_ICON;},3000);
    } else {
      const offset=C-(pct/100)*C;
      el.innerHTML='<svg class="dl-ring" viewBox="0 0 28 28"><circle class="dl-ring-bg" cx="14" cy="14" r="'+R+'"/><circle class="dl-ring-fill" cx="14" cy="14" r="'+R+'" style="stroke-dashoffset:'+offset+'"/></svg>';
    }
  }

  function makeDlBtn(mid,downloadedPaths){
    const paths=downloadedPaths||JSON.parse(localStorage.getItem('qqmusic_downloaded_paths')||'{}');
    if(paths[mid]){
      return '<span class="dl-btn dl-downloaded" data-folder-mid="'+mid+'" onclick="App.openFileFolder(\''+mid+'\')" title="打开文件夹"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg></span>';
    }
    return '<span class="dl-btn" data-dl-mid="'+mid+'" onclick="App.downloadSong(\''+mid+'\')">'+DOWNLOAD_ICON+'</span>';
  }

  function makeAddBtn(mid,added){
    if(added){
      return '<span class="add-btn added" title="已添加"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--text-tertiary)" stroke-width="2.5"><path d="M20 6L9 17l-5-5"/></svg></span>';
    }
    return '<span class="add-btn" data-add-mid="'+mid+'" tabindex="0">'+
      '<span class="add-btn-header" onclick="App.toggleAddBtn(event,\''+mid+'\')"><span class="add-btn-icon"></span></span>'+
      '<span class="add-btn-popup">'+
      '<span class="add-btn-popup-header" onclick="App.toggleAddBtn(event,\''+mid+'\')"><span class="add-btn-popup-icon"></span></span>'+
      '<span class="add-btn-item" onclick="App.addToTop(\''+mid+'\',event)">添加到歌单顶部</span>'+
      '<span class="add-btn-item" onclick="App.addSong(\''+mid+'\',event)">添加到歌单底部</span>'+
      '</span></span>';
  }

  function collapseAllAddBtns(){
    document.querySelectorAll('.add-btn.expanded').forEach(el=>el.classList.remove('expanded'));
  }

  function saveDownloadedPath(mid,filePath){
    const paths=JSON.parse(localStorage.getItem('qqmusic_downloaded_paths')||'{}');
    paths[mid]=filePath;
    localStorage.setItem('qqmusic_downloaded_paths',JSON.stringify(paths));
  }

  function removeDownloadedPath(mid){
    const paths=JSON.parse(localStorage.getItem('qqmusic_downloaded_paths')||'{}');
    delete paths[mid];
    localStorage.setItem('qqmusic_downloaded_paths',JSON.stringify(paths));
  }

  async function verifyDownloadedPaths(){
    if(!window.electronAPI||!window.electronAPI.fileExists) return;
    const paths=JSON.parse(localStorage.getItem('qqmusic_downloaded_paths')||'{}');
    let changed=false;
    for(const mid of Object.keys(paths)){
      const exists=await window.electronAPI.fileExists(paths[mid]);
      if(!exists){delete paths[mid];changed=true;}
    }
    if(changed) localStorage.setItem('qqmusic_downloaded_paths',JSON.stringify(paths));
  }

  function getSourceIcon(source){
    return source==='netease'?SOURCE_NETEASE_ICON:SOURCE_QQ_ICON;
  }

  let toastIdCounter=0;

  function showToast(msg,type,duration){
    type=type||'info';
    duration=duration||3000;
    const container=$('toast-container');
    const el=document.createElement('div');
    const id='toast-'+(++toastIdCounter);
    el.id=id;
    el.className='toast toast-'+type;
    const icons={
      success:'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 6L9 17l-5-5"/></svg>',
      error:'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>',
      info:'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="17" x2="12" y2="12"/><circle cx="12" cy="6.5" r="1.5" fill="currentColor" stroke="none"/></svg>',
      progress:'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="spin"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>'
    };
    el.innerHTML='<span class="toast-icon">'+(icons[type]||icons.info)+'</span><span class="toast-text">'+msg+'</span>';
    container.appendChild(el);
    if(duration>0) setTimeout(()=>{el.classList.add('toast-out');setTimeout(()=>el.remove(),200);},duration);
    return id;
  }

  function updateToast(id,msg,type){
    const el=$(id);
    if(!el) return;
    const textEl=el.querySelector('.toast-text');
    if(textEl) textEl.textContent=msg;
    if(type){
      const icons={
        success:'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 6L9 17l-5-5"/></svg>',
        error:'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>',
        info:'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="17" x2="12" y2="12"/><circle cx="12" cy="6.5" r="1.5" fill="currentColor" stroke="none"/></svg>'
      };
      el.className='toast toast-'+type;
      const iconEl=el.querySelector('.toast-icon');
      if(iconEl&&icons[type]) iconEl.innerHTML=icons[type];
    }
  }

  function dismissToast(id){
    const el=$(id);
    if(!el) return;
    el.classList.add('toast-out');
    setTimeout(()=>el.remove(),200);
  }

  function trimSong(s){
    return {mid:s.mid,name:s.name,artist:s.artist,pic:s.pic||'',link:s.link||'',mediaMid:s.mediaMid||'',source:s.source||'qq'};
  }

  function saveSongs(){
    const trimmed=state.songs.map(trimSong);
    localStorage.setItem('qqmusic_songs',JSON.stringify(trimmed));
  }
  function loadSongs(){
    try{state.songs=JSON.parse(localStorage.getItem('qqmusic_songs')||'[]');}catch(e){state.songs=[];}
  }

  const PAGE_ORDER=['search','playlist','settings','about'];

  function navigate(page){
    const main=$('main-content');
    const currentPage=document.querySelector('.page.active');
    if(currentPage&&main){
      const curId=currentPage.id.replace('page-','');
      state.pageScrolls[curId]=main.scrollTop;
    }

    const current=currentPage;
    const next=document.getElementById('page-'+page);
    if(current===next&&page!=='playlist'&&page!=='settings') return;

    document.querySelectorAll('.page').forEach(p=>{
      p.classList.remove('active');
      p.style.transition='';
      p.style.opacity='';
      p.style.transform='';
    });
    next.classList.add('active');

    const fromIdx=PAGE_ORDER.indexOf(current?current.id.replace('page-',''):'');
    const toIdx=PAGE_ORDER.indexOf(page);
    const dir=toIdx>=fromIdx?1:-1;

    document.querySelectorAll('.nav-item').forEach(n=>{
      n.classList.toggle('active',n.dataset.page===page);
    });

    if(current&&current!==next){
      current.style.transition='opacity 0.2s ease,transform 0.2s ease';
      current.style.opacity='0';
      current.style.transform='translateX('+(-dir*30)+'px)';
      setTimeout(()=>{
        current.style.transition='';
        current.style.opacity='';
        current.style.transform='';
      },200);
    }

    if(next){
      next.style.opacity='0';
      next.style.transform='translateX('+(dir*30)+'px)';
      requestAnimationFrame(()=>{
        requestAnimationFrame(()=>{
          next.style.transition='opacity 0.25s ease,transform 0.25s ease';
          next.style.opacity='1';
          next.style.transform='translateX(0)';
          setTimeout(()=>{next.style.transition='';},260);
        });
      });
    }

    if(page==='playlist') verifyDownloadedPaths().then(()=>renderPlaylist());
    if(page==='settings') loadSettings();

    if(main) main.scrollTop=state.pageScrolls[page]||0;
  }

  function updatePlaylistBadge(){
    const badge=$('playlist-count');
    if(state.songs.length>0){
      badge.style.display='';
      badge.textContent=state.songs.length;
    } else {
      badge.style.display='none';
    }
  }

  function isAdded(mid){return state.songs.some(s=>s.mid===mid);}

  function addToList(song){
    if(isAdded(song.mid)) return false;
    state.songs.push(song);
    saveSongs();
    updatePlaylistBadge();
    return true;
  }

  function removeFromList(mid){
    state.songs=state.songs.filter(s=>s.mid!==mid);
    state.selectedMids=state.selectedMids.filter(m=>m!==mid);
    saveSongs();
    updatePlaylistBadge();
  }

  function clearList(){
    state.songs=[];
    state.selectedMids=[];
    saveSongs();
    updatePlaylistBadge();
  }

  function renderSearchResults(){
    const container=$('search-results');
    const pagination=$('search-pagination');
    const hero=$('search-hero');
    const center=$('search-center');

    if(!state.searchResults||state.searchResults.length===0){
      container.innerHTML='';
      pagination.style.display='none';
      if(!state.searchKeyword&&center) center.classList.remove('has-results');
      if(!state.searchKeyword) hero.style.display='';
      return;
    }

    if(hero) hero.style.display='none';
    if(center) center.classList.add('has-results');
    let html='<div class="results-header"><div class="results-title-group"><h3>'+esc(state.searchKeyword||'搜索结果')+'</h3><span class="results-count">'+state.searchResults.length+' 首</span></div>';
    html+='<div class="results-actions">';
    html+='<button class="btn btn-sm btn-accent" onclick="App.addAllResults()">全部添加</button>';
    html+='<button class="btn btn-sm btn-primary" onclick="App.batchDownloadSmart()">'+DOWNLOAD_ICON_SM+' 批量下载</button>';
    html+='</div></div>';
    html+='<div class="results-grid">';

    state.searchResults.forEach(song=>{
      const added=isAdded(song.mid);
      const coverHtml=song.pic
        ?'<img class="song-cover" src="'+Api.getProxyImageUrl(song.pic)+'" alt="" loading="lazy">'
        :'<div class="song-cover-placeholder"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg></div>';

      html+='<div class="song-card" data-mid="'+song.mid+'">';
      html+=coverHtml;
      html+='<div class="song-info"><div class="song-name">'+getSourceIcon(song.source)+' '+esc(song.name)+'</div><div class="song-artist">'+esc(song.artist)+'</div></div>';
      html+='<div class="song-actions">';
      html+='<button class="btn-icon accent" title="试听" onclick="App.playSong(\''+song.mid+'\')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"/></svg></button>';
      html+=makeDlBtn(song.mid);
      html+=makeAddBtn(song.mid,added);
      html+='</div></div>';
    });
    html+='</div>';
    container.innerHTML=html;

    if(state.searchKeyword){
      const totalPages=Math.max(1,Math.ceil(state.searchTotal/50));
      const hasNext=state.currentPage<totalPages;
      pagination.style.display='flex';
      pagination.innerHTML='<button class="btn btn-secondary" onclick="App.changePage('+(state.currentPage-1)+')" '+(state.currentPage<=1?'disabled':'')+'>上一页</button>';
      pagination.innerHTML+='<span style="font-size:13px;color:var(--text-secondary)">第 '+state.currentPage+'/'+totalPages+' 页</span>';
      pagination.innerHTML+='<button class="btn btn-secondary" onclick="App.changePage('+(state.currentPage+1)+')" '+(!hasNext?'disabled':'')+'>下一页</button>';
    } else {
      pagination.style.display='none';
    }
  }

  function renderPlaylist(){
    const empty=$('playlist-empty');
    const content=$('playlist-content');
    const actions=$('playlist-actions');
    const batchBar=$('playlist-batch-bar');

    if(state.songs.length===0){
      empty.style.display='';
      content.innerHTML='';
      actions.innerHTML='';
      batchBar.style.display='none';
      return;
    }

    empty.style.display='none';
    actions.innerHTML='<button class="btn btn-sm btn-secondary" onclick="App.selectAll()">全选</button>';
    actions.innerHTML+='<button class="btn btn-sm btn-secondary" onclick="App.clearPlaylist()">清空</button>';
    actions.innerHTML+='<button class="btn btn-sm btn-accent" onclick="App.exportPlaylist()">导出</button>';
    actions.innerHTML+='<button class="btn btn-sm btn-primary" onclick="App.batchDownloadPlaylist()">'+DOWNLOAD_ICON_SM+' 批量下载</button>';

    content.innerHTML='';
    const downloadedPaths=JSON.parse(localStorage.getItem('qqmusic_downloaded_paths')||'{}');
    const BATCH=100;
    let idx=0;

    function renderBatch(){
      const frag=document.createDocumentFragment();
      const end=Math.min(idx+BATCH,state.songs.length);
      for(let i=idx;i<end;i++){
        const song=state.songs[i];
        const checked=state.selectedMids.includes(song.mid)?'checked':'';
        const isPlaying=Player.currentSong&&Player.currentSong.mid===song.mid;
        const div=document.createElement('div');
        div.className='playlist-item'+(isPlaying?' playing':'');
        const coverHtml=song.pic
          ?'<img class="song-cover" data-src="'+Api.getProxyImageUrl(song.pic)+'" src="'+TINY_COVER+'" alt="">'
          :'<div class="song-cover-placeholder"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg></div>';
        div.innerHTML='<input type="checkbox" '+checked+' data-mid="'+song.mid+'" onchange="App.toggleSelect(\''+song.mid+'\')">'
          +coverHtml
          +'<div class="song-info"><div class="song-name">'+getSourceIcon(song.source)+' '+esc(song.name)+'</div><div class="song-artist">'+esc(song.artist)+'</div></div>'
          +'<div class="playlist-item-actions"><div class="playlist-item-btns">'
          +'<button class="btn-icon accent" title="试听" onclick="App.playSong(\''+song.mid+'\')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"/></svg></button>'
          +makeDlBtn(song.mid,downloadedPaths)
          +'<button class="btn-icon" title="歌词" onclick="App.viewLyric(\''+song.mid+'\')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg></button>'
          +'<button class="btn-icon" title="删除" onclick="App.removeSong(\''+song.mid+'\')"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button>'
          +'</div></div>';
        frag.appendChild(div);
      }
      content.appendChild(frag);
      idx=end;
      if(idx<state.songs.length){
        requestAnimationFrame(renderBatch);
      } else {
        ensurePlaylistImageObserver();
        content.querySelectorAll('img.song-cover[data-src]').forEach(img=>{
          playlistImageObserver.observe(img);
        });
      }
    }

    requestAnimationFrame(renderBatch);

    if(state.selectedMids.length>0){
      batchBar.style.display='flex';
      batchBar.innerHTML='<div class="batch-info">已选择 <strong>'+state.selectedMids.length+'</strong> 首</div>';
      batchBar.innerHTML+='<button class="btn btn-sm btn-secondary" onclick="App.invertSelect()">反选</button>';
      batchBar.innerHTML+='<button class="btn btn-sm btn-secondary" onclick="App.deleteSelected()">删除</button>';
      batchBar.innerHTML+='<button class="btn btn-sm btn-primary" onclick="App.batchDownloadSmart()">'+DOWNLOAD_ICON_SM+' 批量下载</button>';
    } else {
      batchBar.style.display='none';
    }
  }

  function updatePlaylistPlayingState(){
    const content=$('playlist-content');
    if(!content) return;
    content.querySelectorAll('.playlist-item.playing').forEach(el=>el.classList.remove('playing'));
    if(Player.currentSong){
      const checkbox=content.querySelector('input[data-mid="'+Player.currentSong.mid+'"]');
      if(checkbox) checkbox.closest('.playlist-item').classList.add('playing');
    }
  }

  function updateBatchBar(){
    const batchBar=$('playlist-batch-bar');
    if(state.selectedMids.length>0){
      batchBar.style.display='flex';
      batchBar.innerHTML='<div class="batch-info">已选择 <strong>'+state.selectedMids.length+'</strong> 首</div>'+
        '<button class="btn btn-sm btn-secondary" onclick="App.invertSelect()">反选</button>'+
        '<button class="btn btn-sm btn-secondary" onclick="App.deleteSelected()">删除</button>'+
        '<button class="btn btn-sm btn-primary" onclick="App.batchDownloadSmart()">'+DOWNLOAD_ICON_SM+' 批量下载</button>';
    } else {
      batchBar.style.display='none';
    }
  }

  function esc(s){
    if(!s) return '';
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

  function findSong(mid){
    return state.searchResults.find(s=>s.mid===mid)||state.songs.find(s=>s.mid===mid);
  }

  function triggerDownload(url,filename){
    const a=document.createElement('a');
    a.href=url;
    a.download=filename;
    a.target='_blank';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  }

  function escapePath(p){
    return String(p||'').replace(/\\/g,'\\\\');
  }

  function sanitizeFilename(name){
    return String(name||'').replace(/[\/\\:*?"<>|]/g,'_').replace(/\s+/g,' ').trim();
  }

  function showSaveDialog(filename,songData){
    return new Promise((resolve)=>{
      const overlay=$('save-dialog-overlay');
      const pathInput=$('save-path-input');
      const fileInput=$('save-filename-input');
      const recentList=$('recent-dirs-list');

      pathInput.value=state.savePath||'';
      fileInput.value=filename||'song.mp3';

      let recentHtml='';
      state.recentDirs.forEach(dir=>{
        recentHtml+='<div class="recent-dir-item" onclick="App.selectRecentDir(\''+escapePath(dir)+'\')">';
        recentHtml+='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';
        recentHtml+='<span>'+esc(dir)+'</span></div>';
      });
      recentList.innerHTML=recentHtml;

      showModal('save-dialog-overlay');
      overlay._resolve=resolve;
    });
  }

  function closeSaveDialog(result){
    const overlay=$('save-dialog-overlay');
    hideModal('save-dialog-overlay');
    if(overlay._resolve) overlay._resolve(result);
  }

  function selectRecentDir(dir){
    state.savePath=dir;
    $('save-path-input').value=dir;
  }

  function addRecentDir(dir){
    state.recentDirs=state.recentDirs.filter(d=>d!==dir);
    state.recentDirs.unshift(dir);
    if(state.recentDirs.length>5) state.recentDirs=state.recentDirs.slice(0,5);
    localStorage.setItem('qqmusic_recent_dirs',JSON.stringify(state.recentDirs));
    localStorage.setItem('qqmusic_save_path',dir);
  }

  async function doDownload(song){
    const filename=sanitizeFilename(song.name)+' - '+sanitizeFilename(song.artist)+'.mp3';
    const useCustomDialog=!!(window.electronAPI);

    if(useCustomDialog){
      try{
        const result=await showSaveDialog(filename,song);
        if(!result||!result.path){
          const el=document.querySelector('[data-dl-mid="'+song.mid+'"]');
          if(el) el.innerHTML=DOWNLOAD_ICON;
          return;
        }

        setDlRing(song.mid,0);
        const data=await Api.downloadSong(song,result.filename);
        const audioUrl=Api.getProxyAudioUrl(data.url);
        if(!audioUrl){setDlRing(song.mid,0,'fail');return;}

        const xhr=new XMLHttpRequest();
        xhr.open('GET',audioUrl);
        xhr.responseType='blob';

        xhr.onprogress=(e)=>{
          if(e.lengthComputable){
            setDlRing(song.mid,Math.round(e.loaded/e.total*100));
          }
        };

        xhr.onload=async()=>{
          if(xhr.status===200){
            const blob=xhr.response;
            const uint8Array=new Uint8Array(await blob.arrayBuffer());
            const savedPath=await window.electronAPI.saveFile(result.path+'/'+result.filename,uint8Array);
            if(savedPath){
              addRecentDir(result.path);
              saveDownloadedPath(song.mid,savedPath);
              setDlRing(song.mid,100,'done');
              showToast('下载完成: '+result.filename,'success');
            }
          } else {
            setDlRing(song.mid,0,'fail');
            console.error('[Download] HTTP',xhr.status,'url:',audioUrl);
            showToast('下载失败: HTTP '+xhr.status,'error');
          }
        };

        xhr.onerror=()=>{
          setDlRing(song.mid,0,'fail');
          console.error('[Download] Network error url:',audioUrl);
          showToast('下载失败','error');
        };

        xhr.send();
      }catch(err){
        setDlRing(song.mid,0,'fail');
        console.error('[Download] Error:',err.message);
        showToast('下载失败: '+err.message,'error');
      }
    } else {
      try{
        setDlRing(song.mid,0);
        const data=await Api.downloadSong(song,filename);
        const audioUrl=Api.getProxyAudioUrl(data.url);
        if(!audioUrl){setDlRing(song.mid,0,'fail');return;}

        const xhr=new XMLHttpRequest();
        xhr.open('GET',audioUrl);
        xhr.responseType='blob';

        xhr.onprogress=(e)=>{
          if(e.lengthComputable){
            setDlRing(song.mid,Math.round(e.loaded/e.total*100));
          }
        };

        xhr.onload=()=>{
          if(xhr.status===200){
            const url=URL.createObjectURL(xhr.response);
            try{
              triggerDownload(url,filename);
              setDlRing(song.mid,100,'done');
              showToast('下载完成','success');
            }finally{
              URL.revokeObjectURL(url);
            }
          } else {
            setDlRing(song.mid,0,'fail');
            console.error('[Download] HTTP',xhr.status,'url:',audioUrl);
            showToast('下载失败','error');
          }
        };

        xhr.onerror=()=>{
          setDlRing(song.mid,0,'fail');
          console.error('[Download] Network error url:',audioUrl);
          showToast('下载失败','error');
        };

        xhr.send();
      }catch(err){
        setDlRing(song.mid,0,'fail');
        console.error('[Download] Error:',err.message);
        showToast('下载失败: '+err.message,'error');
      }
    }
  }

  async function doBatchDownload(songs){
    if(songs.length===0) return;

    let saveDir=state.savePath;
    if(!saveDir&&window.electronAPI){
      saveDir=await window.electronAPI.selectDirectory();
      if(!saveDir) return;
      state.savePath=saveDir;
      localStorage.setItem('qqmusic_save_path',saveDir);
    }

    const toastId=showToast('批量下载 '+songs.length+' 首...','info',0);

    try{
      const res=await Api.api.getBatchUrls(songs,state.highQuality);
      const urls=res.data;
      let ok=0,fail=0;

      for(let i=0;i<urls.length;i++){
        const item=urls[i];
        // updateToast(toastId,'批量下载 '+(i+1)+'/'+urls.length,'info');

        if(item.url){
          try{
            const filename=sanitizeFilename(item.name||'未知')+' - '+sanitizeFilename(item.artist||'未知')+'.mp3';
            updateSongProgress(item.mid,0);
            if(saveDir){
              const data=await Api.downloadSong(item,filename);
              if(data&&data.url){
                const xhr=new XMLHttpRequest();
                xhr.open('GET',Api.getProxyAudioUrl(data.url));xhr.responseType='blob';
                xhr.onprogress=(e)=>{
                  if(e.lengthComputable){
                    updateSongProgress(item.mid,Math.round(e.loaded/e.total*100));
                  }
                };
                await new Promise((resolve,reject)=>{
                  xhr.onload=async()=>{
                    if(xhr.status===200){
                      const buf=new Uint8Array(await xhr.response.arrayBuffer());
                      await window.electronAPI.saveFile(saveDir+'/'+filename,buf);
                      saveDownloadedPath(item.mid,saveDir+'/'+filename);
                      resolve();
                    } else {
                      console.error('[Batch] HTTP',xhr.status,'url:',Api.getProxyAudioUrl(data.url));
                      reject(new Error('HTTP '+xhr.status));
                    }
                  };
                  xhr.onerror=()=>reject(new Error('网络错误'));
                  xhr.send();
                });
                updateSongProgress(item.mid,100,'done');
                ok++;
              } else {updateSongProgress(item.mid,0,'fail');fail++;}
            } else {
              updateSongProgress(item.mid,0);
              const blob=await new Promise((resolve,reject)=>{
                const xhr=new XMLHttpRequest();
                xhr.open('GET',Api.getProxyAudioUrl(item.url));xhr.responseType='blob';
                xhr.onprogress=(e)=>{
                  if(e.lengthComputable){
                    updateSongProgress(item.mid,Math.round(e.loaded/e.total*100));
                  }
                };
                xhr.onload=()=>xhr.status===200?resolve(xhr.response):reject(new Error('HTTP '+xhr.status));
                xhr.onerror=()=>reject(new Error('网络错误'));
                xhr.send();
              });
              const url=URL.createObjectURL(blob);
              try{
                triggerDownload(url,filename);
                updateSongProgress(item.mid,100,'done');
                ok++;
              }finally{
                URL.revokeObjectURL(url);
              }
            }
          }catch(e){console.error('[Batch] Error:',e.message);updateSongProgress(item.mid,0,'fail');fail++;}
        } else {console.error('[Batch] No url for item:',item?.name||'?');updateSongProgress(item.mid,0,'fail');fail++;}
      }

      if(ok>0){
        updateToast(toastId,'成功下载 '+ok+' 首'+(fail>0?'，'+fail+' 首失败':''),'success');
      } else {
        updateToast(toastId,'下载失败','error');
      }
      setTimeout(()=>dismissToast(toastId),3000);
    }catch(err){
      updateToast(toastId,'批量下载失败: '+err.message,'error');
      setTimeout(()=>dismissToast(toastId),3000);
    }
  }

  function updateSongProgress(mid,pct,status){
    if(status==='done'){
      setDlRing(mid,100,'done');
    } else if(status==='fail'){
      setDlRing(mid,0,'fail');
    } else {
      setDlRing(mid,pct||0);
    }
  }

  async function handleSearch(){
    if(state.isSearching) return;
    state.isSearching=true;
    const input=$('search-input');
    const keyword=input.value.trim();
    if(!keyword){state.isSearching=false;return;}

    const btn=$('search-btn');
    btn.disabled=true;
    document.querySelectorAll('.source-tab').forEach(t=>t.classList.add('searching'));
    btn.classList.add('loading');

    try{
      const qqPlaylistRe=/y\.qq\.com.*playlist\/(\d+)/;
      const qqSongRe=/song\/(\w+)/;
      const neteasePlaylistRe=/music\.163\.com.*playlist\?id=(\d+)/;
      const neteaseSongRe=/music\.163\.com.*song\?id=(\d+)/;
      const playlistRe=/playlist\/(\d+)/;
      const songRe=/song\/(\w+)/;
      const idRe=/[?&]id=(\d+)/;
      const numRe=/^\d+$/;

      let m;

      if((m=keyword.match(neteasePlaylistRe))){
        const toastId=showToast('网易云音乐 歌单加载中...歌曲过多可能需要十几秒种加载~','info',0);
        try{
          const res=await Api.neteaseApi.getPlaylist(m[1]);
          dismissToast(toastId);
          if(res.data&&res.data.list&&res.data.list.length>0){
            state.searchResults=res.data.list;
            state.searchKeyword=res.data.name||'网易云歌单';
            state.currentPage=1;
            state.isPlaylistPage=true;
            showToast('歌曲加载完成~','success');
            renderSearchResults();
          } else {
            showToast('歌单为空或获取失败','error');
          }
        }catch(err){
          dismissToast(toastId);
          showToast('歌单加载失败 '+err.message,'error');
        }
      } else if((m=keyword.match(neteaseSongRe))){
        const searchRes=await Api.neteaseApi.search(keyword,1,1);
        if(searchRes.data&&searchRes.data.length>0){
          addToList(searchRes.data[0]);
          state.searchResults=[];
          state.searchKeyword='';
          showToast('已导入: '+searchRes.data[0].name,'success');
          renderSearchResults();
        } else {
          showToast('歌曲不存在','error');
        }
      } else if(state.searchSource==='netease'&&!keyword.match(/y\.qq\.com/)){
        const res=await Api.neteaseApi.search(keyword);
        state.searchResults=res.data||[];
        state.searchTotal=res.total||0;
        state.searchKeyword=keyword;
        state.currentPage=1;
        state.isPlaylistPage=false;
        renderSearchResults();
      } else if((m=keyword.match(playlistRe))||(m=keyword.match(idRe))||(m=keyword.match(numRe))){
        const id=typeof m==='object'?m[1]:m;
        const toastId=showToast('QQ音乐 歌单加载中...歌曲过多可能需要十几秒种加载~','info',0);
        try{
          const res=await Api.api.getPlaylist(id);
          dismissToast(toastId);
          if(res.data&&res.data.list&&res.data.list.length>0){
            state.searchResults=res.data.list;
            state.searchKeyword=res.data.name||'QQ歌单';
            state.currentPage=1;
            state.isPlaylistPage=true;
            showToast('歌曲加载完成~','success');
            renderSearchResults();
          } else {
            showToast('歌单为空或获取失败','error');
          }
        }catch(err){
          dismissToast(toastId);
          showToast('歌单加载失败 '+err.message,'error');
        }
      } else if((m=keyword.match(songRe))){
        const res=await Api.api.getSongDetail(m[1]);
        if(res.data){
          addToList(res.data);
          state.searchResults=[];
          state.searchKeyword='';
          showToast('已导入: '+res.data.name,'success');
          renderSearchResults();
        } else {
          showToast('歌曲不存在','error');
        }
      } else {
        const res=await Api.api.search(keyword);
        state.searchResults=res.data||[];
        state.searchTotal=res.total||0;
        state.searchKeyword=keyword;
        state.currentPage=1;
        state.isPlaylistPage=false;
        renderSearchResults();
      }
    }catch(err){
      showToast('搜索失败: '+err.message,'error');
    } finally {
      btn.disabled=false;
      btn.classList.remove('loading');
      state.isSearching=false;
      document.querySelectorAll('.source-tab').forEach(t=>t.classList.remove('searching'));
    }
  }

  function applyZoom(v){
    const clamped=Math.max(75,Math.min(150,v));
    const scale=clamped/100;
    
    if(window.electronAPI&&window.electronAPI.setZoomFactor){
      window.electronAPI.setZoomFactor(scale);
    }
    
    const slider=$('zoom-slider');
    const label=$('zoom-value');
    if(slider) slider.value=clamped;
    if(label) label.textContent=clamped+'%';
    localStorage.setItem('qqmusic_zoom',clamped.toString());
  }

  async function loadSettings(){
    const saved=localStorage.getItem('qqmusic_cookie')||'';
    setCookieInputValue(saved);
    state.highQuality=localStorage.getItem('qqmusic_high_quality')!=='false';
    $('hq-toggle').checked=state.highQuality;
    $('hq-badge').style.display=state.highQuality?'':'none';
    updateCookieStatus();
    const sp=localStorage.getItem('qqmusic_save_path')||'';
    if($('default-save-path')) $('default-save-path').value=sp;
    renderRecentDirsManage();

    const zoom=parseInt(localStorage.getItem('qqmusic_zoom')||'100');
    applyZoom(zoom);

    loadNeteaseSettings();
  }

  function loadNeteaseSettings(){
    const saved=localStorage.getItem('netease_cookie')||'';
    setNeteaseCookieInputValue(saved);
    updateNeteaseCookieStatus();
  }

  function renderRecentDirsManage(){
    const el=$('recent-dirs-manage');
    const section=$('recent-dirs-section');
    if(!el||!section) return;
    const dirs=state.recentDirs;
    if(dirs.length===0){section.style.display='none';return;}
    section.style.display='';
    let html='';
    dirs.forEach(dir=>{
      html+='<div class="recent-dir-manage-item">';
      html+='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';
      html+='<span title="'+esc(dir)+'">'+esc(dir)+'</span>';
      html+='<button class="icon-btn" onclick="App.removeRecentDir(\''+escapePath(dir)+'\')" title="删除">';
      html+='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>';
      html+='</button></div>';
    });
    el.innerHTML=html;
  }

  function updateCookieStatus(forceStatus){
    const status=$('cookie-status');
    const saved=localStorage.getItem('qqmusic_cookie')||'';
    const cached=forceStatus||localStorage.getItem('qqmusic_cookie_status')||'pending';
    if(!saved){
      status.className='cookie-status';
      status.querySelector('.status-text').textContent='未配置';
    } else if(cached==='valid'){
      status.className='cookie-status valid';
      status.querySelector('.status-text').textContent='有效';
    } else if(cached==='invalid'){
      status.className='cookie-status invalid';
      status.querySelector('.status-text').textContent='无效';
    } else {
      status.className='cookie-status';
      status.querySelector('.status-text').textContent='已保存（待验证）';
    }
  }

  function setupEventListeners(){
    document.querySelectorAll('.nav-item').forEach(item=>{
      item.addEventListener('click',()=>navigate(item.dataset.page));
    });

    $('search-input').addEventListener('keydown',e=>{if(e.key==='Enter'&&!state.isSearching) handleSearch();});
    $('search-btn').addEventListener('click',handleSearch);

    document.querySelectorAll('.source-tab').forEach(tab=>{
      tab.addEventListener('click',()=>{
        if(state.isSearching) return;
        document.querySelectorAll('.source-tab').forEach(t=>t.classList.remove('active'));
        tab.classList.add('active');
        state.searchSource=tab.dataset.source;
        localStorage.setItem('search_source',state.searchSource);
        if(state.searchKeyword&&state.searchResults.length>0&&!state.isPlaylistPage){
          handleSearch();
        }
      });
    });
    const savedSourceTab=document.querySelector('.source-tab[data-source="'+state.searchSource+'"]');
    if(savedSourceTab){
      document.querySelectorAll('.source-tab').forEach(t=>t.classList.remove('active'));
      savedSourceTab.classList.add('active');
    }

    $('search-input').addEventListener('input',(e)=>{
      const val=e.target.value.trim();
      const isLink=/playlist\/(\d+)|song\/(\w+)|[?&]id=\d+|^\d+$/.test(val);
      const isNeteaseLink=/music\.163\.com/.test(val);
      $('search-btn').classList.toggle('link-style',isLink||isNeteaseLink);
    });

    $('cookie-verify').addEventListener('click',async()=>{
      const cookie=getCookieInputValue();
      if(!cookie){showToast('请输入 Cookie','error');return;}
      const status=$('cookie-status');
      status.className='cookie-status';
      status.querySelector('.status-text').textContent='验证中...';
      try{
        await Api.verifyCookie(cookie);
        localStorage.setItem('qqmusic_cookie_status','valid');
        status.className='cookie-status valid';
        status.querySelector('.status-text').textContent='有效';
        showToast('Cookie 验证通过','success');
      }catch(err){
        localStorage.setItem('qqmusic_cookie_status','invalid');
        status.className='cookie-status invalid';
        status.querySelector('.status-text').textContent='无效';
        showToast(err.message,'error');
      }
    });

    $('cookie-save').addEventListener('click',()=>{
      const cookie=getCookieInputValue();
      if(!cookie){showToast('请输入 Cookie','error');return;}
      localStorage.setItem('qqmusic_cookie',cookie);
      const currentStatus=localStorage.getItem('qqmusic_cookie_status');
      if(currentStatus!=='valid') localStorage.setItem('qqmusic_cookie_status','pending');
      updateCookieStatus();
      showToast('Cookie 已保存','success');
    });

    $('cookie-clear').addEventListener('click',async()=>{
      const ok=await showConfirm('确定清除已保存的 Cookie 吗？');
      if(!ok) return;
      localStorage.removeItem('qqmusic_cookie');
      localStorage.removeItem('qqmusic_cookie_status');
      setCookieInputValue('');
      updateCookieStatus();
      showToast('Cookie 已清除','info');
    });

    $('cookie-toggle-visibility').addEventListener('click',()=>{
      const pw=$('cookie-input-pw');
      const txt=$('cookie-input-text');
      const eyeOpen=$('eye-open');
      const eyeClosed=$('eye-closed');
      if(pw.style.display==='none'){
        pw.value=txt.value;pw.style.display='';txt.style.display='none';
        eyeOpen.style.display='';eyeClosed.style.display='none';
      } else {
        txt.value=pw.value;txt.style.display='';pw.style.display='none';
        eyeOpen.style.display='none';eyeClosed.style.display='';
      }
    });

    $('netease-cookie-verify').addEventListener('click',async()=>{
      const cookie=getNeteaseCookieInputValue();
      if(!cookie){showToast('请输入 MUSIC_U Cookie','error');return;}
      const status=$('netease-cookie-status');
      status.className='cookie-status';
      status.querySelector('.status-text').textContent='验证中...';
      try{
        await Api.verifyNeteaseCookie(cookie);
        localStorage.setItem('netease_cookie_status','valid');
        status.className='cookie-status valid';
        status.querySelector('.status-text').textContent='有效';
        showToast('网易云 Cookie 验证通过','success');
      }catch(err){
        localStorage.setItem('netease_cookie_status','invalid');
        status.className='cookie-status invalid';
        status.querySelector('.status-text').textContent='无效';
        showToast(err.message,'error');
      }
    });

    $('netease-cookie-save').addEventListener('click',()=>{
      const cookie=getNeteaseCookieInputValue();
      if(!cookie){showToast('请输入 MUSIC_U Cookie','error');return;}
      localStorage.setItem('netease_cookie',cookie);
      const currentStatus=localStorage.getItem('netease_cookie_status');
      if(currentStatus!=='valid') localStorage.setItem('netease_cookie_status','pending');
      updateNeteaseCookieStatus();
      showToast('网易云 Cookie 已保存','success');
    });

    $('netease-cookie-clear').addEventListener('click',async()=>{
      const ok=await showConfirm('确定清除已保存的网易云 Cookie 吗？');
      if(!ok) return;
      localStorage.removeItem('netease_cookie');
      localStorage.removeItem('netease_cookie_status');
      setNeteaseCookieInputValue('');
      updateNeteaseCookieStatus();
      showToast('网易云 Cookie 已清除','info');
    });

    $('netease-cookie-toggle-visibility').addEventListener('click',()=>{
      const pw=$('netease-cookie-input-pw');
      const txt=$('netease-cookie-input-text');
      const eyeOpen=$('netease-eye-open');
      const eyeClosed=$('netease-eye-closed');
      if(pw.style.display==='none'){
        pw.value=txt.value;pw.style.display='';txt.style.display='none';
        eyeOpen.style.display='';eyeClosed.style.display='none';
      } else {
        txt.value=pw.value;txt.style.display='';pw.style.display='none';
        eyeOpen.style.display='none';eyeClosed.style.display='';
      }
    });

    $('hq-toggle').addEventListener('change',()=>{
      state.highQuality=$('hq-toggle').checked;
      localStorage.setItem('qqmusic_high_quality',state.highQuality.toString());
      $('hq-badge').style.display=state.highQuality?'':'none';
    });

    const zoomSlider=$('zoom-slider');
    const zoomLabel=$('zoom-value');
    if(zoomSlider){
      zoomSlider.addEventListener('input',()=>{
        if(zoomLabel) zoomLabel.textContent=zoomSlider.value+'%';
      });
      zoomSlider.addEventListener('change',()=>{
        applyZoom(parseInt(zoomSlider.value));
      });
    }

    if(window.electronAPI){
      $('btn-minimize').addEventListener('click',()=>window.electronAPI.minimize());
      $('btn-maximize').addEventListener('click',()=>window.electronAPI.maximize());
      $('btn-close').addEventListener('click',()=>window.electronAPI.close());

      $('save-dialog-close').addEventListener('click',()=>closeSaveDialog(null));
      $('save-dialog-cancel').addEventListener('click',()=>closeSaveDialog(null));
      $('save-dialog-confirm').addEventListener('click',()=>{
        const path=$('save-path-input').value;
        const filename=$('save-filename-input').value;
        if(!path){showToast('请选择保存路径','error');return;}
        if(!filename){showToast('请输入文件名','error');return;}
        closeSaveDialog({path,filename});
      });
      $('save-path-browse').addEventListener('click',async()=>{
        const dir=await window.electronAPI.selectDirectory();
        if(dir){
          state.savePath=dir;
          $('save-path-input').value=dir;
        }
      });

      $('set-default-path').addEventListener('click',async()=>{
        const dir=await window.electronAPI.selectDirectory();
        if(dir){
          state.savePath=dir;
          localStorage.setItem('qqmusic_save_path',dir);
          $('default-save-path').value=dir;
          renderRecentDirsManage();
        }
      });
      $('clear-default-path').addEventListener('click',()=>{
        state.savePath='';
        localStorage.removeItem('qqmusic_save_path');
        $('default-save-path').value='';
      });
    }

    $('lyrics-edit-btn').addEventListener('click',()=>App.editLyric());
    $('lyrics-save-btn').addEventListener('click',()=>App.saveLyric());
    $('lyrics-cancel-btn').addEventListener('click',()=>App.cancelEditLyric());

    $('lyrics-close').addEventListener('click',()=>hideModal('lyrics-overlay'));
$('lyrics-overlay').addEventListener('click',e=>{
  if(e.target===$('lyrics-overlay')){
    const ea=$('lyrics-edit-area');
    if(ea&&ea.style.display!=='none'){
      App.cancelEditLyric();
    }else{
      if(lyricRafId){cancelAnimationFrame(lyricRafId);lyricRafId=null;}
      hideModal('lyrics-overlay');
    }
  }
});

    document.addEventListener('keydown',e=>{
      if($('lyrics-overlay').classList.contains('show')&&state.currentLyricMid){
    const ea=$('lyrics-edit-area');
    if(ea&&ea.style.display!=='none'){
          if(e.key==='Escape'){
            e.preventDefault();
            App.cancelEditLyric();
          }else if(e.key==='s'&&(e.ctrlKey||e.metaKey)){
            e.preventDefault();
            App.saveLyric();
          }
        }
      }
    });

    $('confirm-ok').addEventListener('click',()=>hideModal('confirm-overlay'));
    $('confirm-cancel').addEventListener('click',()=>hideModal('confirm-overlay'));
  }

  function getCookieInputValue(){
    const pw=$('cookie-input-pw');
    return(pw.style.display==='none'?$('cookie-input-text').value:pw.value).trim();
  }

  function setCookieInputValue(v){
    $('cookie-input-pw').value=v;
    $('cookie-input-text').value=v;
  }

  function getNeteaseCookieInputValue(){
    const pw=$('netease-cookie-input-pw');
    return(pw.style.display==='none'?$('netease-cookie-input-text').value:pw.value).trim();
  }

  function setNeteaseCookieInputValue(v){
    $('netease-cookie-input-pw').value=v;
    $('netease-cookie-input-text').value=v;
  }

  function updateNeteaseCookieStatus(forceStatus){
    const status=$('netease-cookie-status');
    const saved=localStorage.getItem('netease_cookie')||'';
    const cached=forceStatus||localStorage.getItem('netease_cookie_status')||'pending';
    if(!saved){
      status.className='cookie-status';
      status.querySelector('.status-text').textContent='未配置';
    } else if(cached==='valid'){
      status.className='cookie-status valid';
      status.querySelector('.status-text').textContent='有效';
    } else if(cached==='invalid'){
      status.className='cookie-status invalid';
      status.querySelector('.status-text').textContent='无效';
    } else {
      status.className='cookie-status';
      status.querySelector('.status-text').textContent='已保存（待验证）';
    }
  }

  function showConfirm(message){
    return new Promise(resolve=>{
      $('confirm-message').textContent=message;
      showModal('confirm-overlay');
      const onOk=()=>{cleanup();resolve(true);};
      const onCancel=()=>{cleanup();resolve(false);};
      function cleanup(){
        hideModal('confirm-overlay');
        $('confirm-ok').removeEventListener('click',onOk);
        $('confirm-cancel').removeEventListener('click',onCancel);
      }
      $('confirm-ok').addEventListener('click',onOk);
      $('confirm-cancel').addEventListener('click',onCancel);
    });
  }

  function showModal(id){
    const el=$(id);
    if(!el) return;
    el.style.display='flex';
    requestAnimationFrame(()=>requestAnimationFrame(()=>el.classList.add('show')));
  }

  function hideModal(id){
    const el=$(id);
    if(!el) return;
    el.classList.remove('show');
    setTimeout(()=>{el.style.display='none';},260);
  }

  function parseLRC(text){
    if(!text) return [];
    const lines=text.split('\n');
    const result=[];
    const re=/\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)/;
    for(const line of lines){
      const m=line.match(re);
      if(m){
        const min=parseInt(m[1]);
        const sec=parseInt(m[2]);
        const ms=parseInt(m[3].length===2?m[3]+'0':m[3]);
        const time=min*60+sec+ms/1000;
        const content=m[4].trim();
        if(content) result.push({time,text:content});
      }
    }
    result.sort((a,b)=>a.time-b.time);
    return result;
  }

  function parseTransLRC(text){
    if(!text) return {};
    const lines=text.split('\n');
    const map={};
    const re=/\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)/;
    for(const line of lines){
      const m=line.match(re);
      if(m){
        const min=parseInt(m[1]);
        const sec=parseInt(m[2]);
        const ms=parseInt(m[3].length===2?m[3]+'0':m[3]);
        const time=min*60+sec+ms/1000;
        const content=m[4].trim();
        if(content) map[time]=content;
      }
    }
    return map;
  }

  function sendErrorToBackend(err,extra){
    try{
      const payload={
        level:'error',
        message:err.message||String(err),
        stack:err.stack||'',
        url:extra&&extra.url||'',
        line:extra&&extra.line||'',
        col:extra&&extra.col||''
      };
      navigator.sendBeacon(Api.BASE+'/api/log',JSON.stringify(payload));
    }catch(e){}
  }

  function setupErrorLogging(){
    window.addEventListener('error',(e)=>{
      sendErrorToBackend(e.error||new Error(e.message),{url:e.filename,line:e.lineno,col:e.colno});
    });
    window.addEventListener('unhandledrejection',(e)=>{
      const err=e.reason instanceof Error?e.reason:new Error(String(e.reason));
      sendErrorToBackend(err);
    });
  }

  const App={
    playSong(mid, manual=true){
      const song=findSong(mid);
      if(!song){showToast('歌曲不存在','error');return;}
      if(Player.playMode==='shuffle'){
        if(manual) buildShufflePlaylist(mid);
        pushHistory(mid);
      }
      const card=document.querySelector('[data-mid="'+mid+'"]');
      if(card) card.classList.add('song-loading');
      Api.api.getSongUrl(mid,true,song).then(res=>{
        if(card) card.classList.remove('song-loading');
        if(res.data&&res.data.url){
          Player.play({...song,url:res.data.url});
          Player.setPlaylist(state.songs);
          updatePlaylistPlayingState();
        } else {
          showToast('无法获取播放链接','error');
        }
      }).catch(err=>{
        if(card) card.classList.remove('song-loading');
        showToast('播放失败: '+err.message,'error');
      });
    },

    async downloadSong(mid){
      const song=findSong(mid);
      if(!song){showToast('歌曲不存在','error');return;}
      setDlRing(mid,0);
      await doDownload(song);
    },

    async openFileFolder(mid){
      const paths=JSON.parse(localStorage.getItem('qqmusic_downloaded_paths')||'{}');
      const filePath=paths[mid];
      if(!filePath){showToast('文件路径不存在','error');return;}
      if(window.electronAPI&&window.electronAPI.showItemInFolder){
        await window.electronAPI.showItemInFolder(filePath);
      }
    },

    addSong(mid,ev){
      if(ev){ev.stopPropagation();}
      collapseAllAddBtns();
      const song=findSong(mid);
      if(!song) return;
      if(addToList(song)){
        showToast('已添加: '+song.name,'success');
        const btn=document.querySelector('[data-add-mid="'+mid+'"]');
        if(btn){
          btn.classList.add('added');
          btn.innerHTML='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--text-tertiary)" stroke-width="2.5"><path d="M20 6L9 17l-5-5"/></svg>';
        }
      }
    },

    addToTop(mid,ev){
      ev.stopPropagation();
      collapseAllAddBtns();
      const song=findSong(mid);
      if(!song) return;
      if(isAdded(song.mid)){showToast('已存在: '+song.name,'info');return;}
      state.songs.unshift(song);
      saveSongs();
      updatePlaylistBadge();
      showToast('已置顶: '+song.name,'success');
      const btn=document.querySelector('[data-add-mid="'+mid+'"]');
      if(btn){
        btn.classList.add('added');
        btn.innerHTML='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--text-tertiary)" stroke-width="2.5"><path d="M20 6L9 17l-5-5"/></svg>';
      }
    },

    toggleAddBtn(ev,mid){
      ev.stopPropagation();
      const btn=ev.currentTarget.closest('.add-btn');
      if(!btn) return;
      const wasExpanded=btn.classList.contains('expanded');
      collapseAllAddBtns();
      if(!wasExpanded){
        btn.classList.add('expanded');
        btn.classList.remove('popup-left','popup-up');
        const popup=btn.querySelector('.add-btn-popup');
        if(popup){
          const r=btn.getBoundingClientRect();
          const pw=popup.offsetWidth;
          const ph=popup.offsetHeight;
          const vw=window.innerWidth;
          const vh=window.innerHeight-(document.body.classList.contains('has-player')?72:0);
          if(r.left+pw>vw) btn.classList.add('popup-left');
          if(r.top+ph>vh) btn.classList.add('popup-up');
        }
      }
    },

    removeSong(mid){
      removeFromList(mid);
      renderPlaylist();
    },

    addAllResults(){
      let count=0;
      const toAdd=[];
      state.searchResults.forEach(s=>{
        if(!isAdded(s.mid)){
          toAdd.push(s);
          count++;
        }
      });
      if(count>0){
        state.songs.unshift(...toAdd);
        saveSongs();
        updatePlaylistBadge();
      }
      state.searchResults.forEach(s=>{
        const btn=document.querySelector('[data-add-mid="'+s.mid+'"]');
        if(btn){
          btn.classList.add('added');
          btn.innerHTML='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--text-tertiary)" stroke-width="2.5"><path d="M20 6L9 17l-5-5"/></svg>';
        }
      });
      if(count>0) showToast('已置顶 '+count+' 首','success');
    },

    batchDownloadResults(){
      doBatchDownload(state.searchResults);
    },

    batchDownloadPlaylist(){
      const songs=state.selectedMids.length>0
        ?state.songs.filter(s=>state.selectedMids.includes(s.mid))
        :state.songs;
      doBatchDownload(songs);
    },

    batchDownloadSelected(){
      const selected=state.songs.filter(s=>state.selectedMids.includes(s.mid));
      doBatchDownload(selected);
    },

    batchDownloadSmart(){
      let songs;
      if(state.selectedMids.length>0){
        songs=state.songs.filter(s=>state.selectedMids.includes(s.mid));
      } else {
        songs=state.songs;
      }
      if(songs.length===0){showToast('没有歌曲可下载','error');return;}
      doBatchDownload(songs);
    },

    toggleSelect(mid){
      if(state.selectedMids.includes(mid)){
        state.selectedMids=state.selectedMids.filter(m=>m!==mid);
      } else {
        state.selectedMids.push(mid);
      }
      const cb=document.querySelector('.playlist-item input[data-mid="'+mid+'"]');
      if(cb) cb.checked=state.selectedMids.includes(mid);
      updateBatchBar();
    },

    selectAll(){
      const allSelected=state.selectedMids.length===state.songs.length;
      state.selectedMids=allSelected?[]:state.songs.map(s=>s.mid);
      document.querySelectorAll('.playlist-item input[type="checkbox"]').forEach((cb,i)=>{
        if(i<state.songs.length) cb.checked=!allSelected;
      });
      updateBatchBar();
    },

    invertSelect(){
      state.selectedMids=state.songs.filter(s=>!state.selectedMids.includes(s.mid)).map(s=>s.mid);
      state.songs.forEach(s=>{
        const cb=document.querySelector('.playlist-item input[data-mid="'+s.mid+'"]');
        if(cb) cb.checked=state.selectedMids.includes(s.mid);
      });
      updateBatchBar();
    },

    deleteSelected(){
      if(state.selectedMids.length===0) return;
      state.songs=state.songs.filter(s=>!state.selectedMids.includes(s.mid));
      state.selectedMids=[];
      saveSongs();
      updatePlaylistBadge();
      renderPlaylist();
    },

    async clearPlaylist(){
      const ok=await showConfirm('确定清空所有歌曲吗？');
      if(!ok) return;
      clearList();
      renderPlaylist();
    },

    exportPlaylist(){
      if(state.songs.length===0){showToast('歌单为空','error');return;}
      let md='# 我的歌单\n\n';
      md+='| # | 歌曲名 | 歌手 |\n|---|--------|------|\n';
      state.songs.forEach((s,i)=>{md+='| '+(i+1)+' | '+s.name+' | '+s.artist+' |\n';});
      md+='\n导出时间: '+new Date().toLocaleString()+'\n共 '+state.songs.length+' 首\n';
      const blob=new Blob([md],{type:'text/markdown;charset=utf-8'});
      const url=URL.createObjectURL(blob);
      const a=document.createElement('a');
      a.href=url;a.download='歌单_'+new Date().toISOString().slice(0,10)+'.md';
      document.body.appendChild(a);a.click();document.body.removeChild(a);
      URL.revokeObjectURL(url);
      showToast('已导出歌单','success');
    },

    async viewLyric(mid, fromEdit){
      const song=findSong(mid);
      const source=song?song.source:'qq';
      state.currentLyricMid=mid;
      try{
        let rawLyric='';
        let transText='';
        const localLrc=localStorage.getItem('custom_lyric_'+mid);
        if(localLrc&&localLrc.trim()){
          rawLyric=localLrc;
        }else{
          const res=source==='netease'
            ?await Api.neteaseApi.getLyric(mid)
            :await Api.api.getLyric(mid);
          const data=res.data;
          rawLyric=data.lyric||'';
          transText=data.trans||'';
        }
        state.currentLyricRaw=rawLyric;
        const parsed=parseLRC(rawLyric);
        state.currentLyricParsed=parsed;
        const transMap=transText?parseTransLRC(transText):{};

        const body=$('lyrics-body');
        const displayArea=$('lyrics-display-area');
        let html='';
        if(parsed.length===0){
          html='<div style="text-align:center;color:var(--text-tertiary);padding:32px">暂无歌词</div>';
        } else {
          parsed.forEach((line,idx)=>{
            const trans=transMap[line.time]||'';
            html+='<div class="lyric-line" data-idx="'+idx+'" data-time="'+line.time+'">'+esc(line.text);
            if(trans) html+='<br><span style="font-size:12px;color:var(--text-tertiary)">'+esc(trans)+'</span>';
            html+='</div>';
          });
        }
        displayArea.innerHTML=html;

        const syncModalLyric=()=>{
          if(!Player.currentSong||Player.currentSong.mid!==mid){
            displayArea.querySelectorAll('.lyric-line').forEach(el=>{
              el.classList.remove('active');
            });
            return;
          }
          const ct=Player.currentTime;
          let activeIdx=-1;
          for(let i=0;i<parsed.length;i++){
            const nextTime=parsed[i+1]?parsed[i+1].time:Infinity;
            if(parsed[i].time<=ct&&nextTime>ct) activeIdx=i;
          }
          displayArea.querySelectorAll('.lyric-line').forEach((el,i)=>{
            el.classList.toggle('active',i===activeIdx);
          });
          return activeIdx;
        };

        if(lyricRafId) cancelAnimationFrame(lyricRafId);
        let lastScrolledIdx=-1;
        const rafLoop=()=>{
          const activeIdx=syncModalLyric();
          if(activeIdx>=0&&activeIdx!==lastScrolledIdx&&lyricAutoFollow){
            const activeEl=displayArea.querySelector('.lyric-line[data-idx="'+activeIdx+'"]');
            if(activeEl){
              isProgrammaticScroll=true;
              activeEl.scrollIntoView({block:'center'});
              setTimeout(()=>{isProgrammaticScroll=false;},500);
              lastScrolledIdx=activeIdx;
            }
          }
          lyricRafId=requestAnimationFrame(rafLoop);
        };
        lyricRafId=requestAnimationFrame(rafLoop);

        const lyricClickHandler=(el)=>{
          const t=parseFloat(el.dataset.time);
          if(isNaN(t)) return;
          const clickMid=state.currentLyricMid;
          if(Player.currentSong&&Player.currentSong.mid===clickMid){
            const dur=Player.getDuration();
            if(isFinite(dur)&&dur>0){
              Player.seek(t/dur);
              syncModalLyric();
            }
          } else {
            App.playSong(clickMid);
            const waitForPlay=()=>{
              const d=Player.getDuration();
              if(isFinite(d)&&d>0){
                Player.seek(t/d);
                syncModalLyric();
              } else {
                setTimeout(waitForPlay,200);
              }
            };
            setTimeout(waitForPlay,500);
          }
        };
        currentLyricClickHandler=lyricClickHandler;

        if(!lyricScrollDelegated){
          displayArea.addEventListener('click',(ev)=>{
            const el=ev.target.closest('.lyric-line');
            if(el&&currentLyricClickHandler) currentLyricClickHandler(el);
          });
          const body=$('lyrics-body');
          if(body){
            body.addEventListener('scroll',()=>{
              if(isProgrammaticScroll) return;
              lyricAutoFollow=false;
              if(lyricScrollTimer) clearTimeout(lyricScrollTimer);
              lyricScrollTimer=setTimeout(()=>{lyricAutoFollow=true;},5000);
            },{passive:true});
          }
          lyricScrollDelegated=true;
        }

        if(Player.currentSong&&Player.currentSong.mid===mid){
          syncModalLyric();
        }

        $('lyrics-title').textContent=(Player.currentSong&&Player.currentSong.mid===mid
          ?Player.currentSong.name+' - '+Player.currentSong.artist
          :findSong(mid)?findSong(mid).name+' - '+findSong(mid).artist:'歌词');
        if(!fromEdit) showModal('lyrics-overlay');

        const closeHandler=()=>{
          hideModal('lyrics-overlay');
          if(lyricRafId){cancelAnimationFrame(lyricRafId);lyricRafId=null;}
          lyricAutoFollow=true;
          if(lyricScrollTimer){clearTimeout(lyricScrollTimer);lyricScrollTimer=null;}
          const ea=$('lyrics-edit-area');
          if(ea&&ea.style.display!=='none'){
            ea.style.display='none';
            ea.classList.remove('mode-entering');
            $('lyrics-display-area').classList.remove('mode-leaving');
            $('lyrics-display-area').style.display='';
            $('lyrics-edit-btn').style.display='';
            $('lyrics-edit-actions').style.display='none';
          }
        };
        if(currentLyricCloseHandler) $('lyrics-close').removeEventListener('click',currentLyricCloseHandler);
        $('lyrics-close').addEventListener('click',closeHandler);
        currentLyricCloseHandler=closeHandler;
      }catch(err){
        showToast('获取歌词失败: '+err.message,'error');
      }
    },

    editLyric() {
      const mid = state.currentLyricMid;
      if (!mid) return;
      const displayArea = $('lyrics-display-area');
      const editArea = $('lyrics-edit-area');
      const textarea = $('lyrics-textarea');
      textarea.value = state.currentLyricRaw || '';
      displayArea.classList.add('mode-leaving');
      $('lyrics-edit-btn').style.display = 'none';
      setTimeout(() => {
        displayArea.style.display = 'none';
        editArea.style.display = 'flex';
        editArea.classList.add('mode-entering');
        textarea.focus({ preventScroll: true });
        const body = $('lyrics-body');
        body.classList.add('no-smooth');
        body.scrollTop = 0;
        textarea.scrollTop = 0;
        body.classList.remove('no-smooth');
      }, 250);
      $('lyrics-edit-actions').style.display = 'flex';
    },

    saveLyric(){
      const mid=state.currentLyricMid;
      if(!mid){showToast('无法保存：歌曲信息丢失','error');return;}
      const textarea=$('lyrics-textarea');
      const text=textarea.value;
      if(!text.trim()){
        localStorage.removeItem('custom_lyric_'+mid);
      }else{
        localStorage.setItem('custom_lyric_'+mid,text);
      }
      state.currentLyricRaw=text;
      App._exitEditMode();
      showToast('歌词已保存','success');
    },

    cancelEditLyric(){
      App._exitEditMode();
    },

    _exitEditMode(){
      const displayArea=$('lyrics-display-area');
      const editArea=$('lyrics-edit-area');
      const body=$('lyrics-body');
      const mid=state.currentLyricMid;
      editArea.classList.add('mode-exiting');
      setTimeout(()=>{
        editArea.style.display='none';
        editArea.classList.remove('mode-entering','mode-exiting');
        displayArea.classList.remove('mode-leaving');
        displayArea.style.display='';
        displayArea.style.opacity='0';
        displayArea.style.transform='translateY(-12px)';
        App.viewLyric(mid, true);
        body.classList.add('no-smooth');
        const active=displayArea.querySelector('.lyric-line.active');
        if(active){
          const lineTop=active.offsetTop;
          const lineHeight=active.offsetHeight;
          const bodyH=body.clientHeight;
          body.scrollTop=Math.max(0,lineTop-bodyH/2+lineHeight/2);
        }else{
          body.scrollTop=0;
        }
        body.classList.remove('no-smooth');
        requestAnimationFrame(()=>{
          requestAnimationFrame(()=>{
            displayArea.style.transition='opacity 0.3s cubic-bezier(0.16,1,0.3,1),transform 0.3s cubic-bezier(0.16,1,0.3,1)';
            displayArea.style.opacity='1';
            displayArea.style.transform='translateY(0)';
            setTimeout(()=>{
              displayArea.style.transition='';
              displayArea.style.opacity='';
              displayArea.style.transform='';
            },320);
          });
        });
      },250);
      $('lyrics-edit-btn').style.display='';
      $('lyrics-edit-actions').style.display='none';
    },

    async changePage(page){
      if(!state.searchKeyword||page<1) return;
      try{
        let res;
        if(state.searchSource==='netease'){
          res=await Api.neteaseApi.search(state.searchKeyword,page);
        } else {
          res=await Api.api.search(state.searchKeyword,page);
        }
        state.searchResults=res.data||[];
        state.searchTotal=res.total||0;
        state.currentPage=page;
        renderSearchResults();
      }catch(err){
        showToast('加载失败: '+err.message,'error');
      }
    },

    selectRecentDir:selectRecentDir,

    removeRecentDir(dir){
      state.recentDirs=state.recentDirs.filter(d=>d!==dir);
      localStorage.setItem('qqmusic_recent_dirs',JSON.stringify(state.recentDirs));
      renderRecentDirsManage();
    },

    init(){
      setupErrorLogging();
      loadSongs();
      loadShuffleState();
      loadPlayHistory();
      ThemeManager.init();
      Player.init();
      Player.setOnModeChange((mode)=>{
        if(mode==='shuffle'){
          buildShufflePlaylist(Player.currentSong?.mid);
        }
      });
      const playerCloseBtn=$('player-close-btn');
      if(playerCloseBtn){playerCloseBtn.addEventListener('click',()=>updatePlaylistPlayingState());}
      setupEventListeners();
      updatePlaylistBadge();
      loadSettings();

      let zoomTimer=null;
      let pendingZoomDelta=0;
      window.addEventListener('wheel',(e)=>{
        if(!e.ctrlKey) return;
        e.preventDefault();
        pendingZoomDelta+=(e.deltaY<0?1:-1);
        if(zoomTimer) return;
        zoomTimer=setTimeout(()=>{
          zoomTimer=null;
          if(pendingZoomDelta===0) return;
          const cur=parseInt(localStorage.getItem('qqmusic_zoom')||'100');
          const next=cur+pendingZoomDelta*5;
          pendingZoomDelta=0;
          applyZoom(next);
        },80);
      },{passive:false});

      window.addEventListener('keydown',(e)=>{
        if(e.ctrlKey&&e.key==='0'){
          e.preventDefault();
          applyZoom(100);
        }
        if(e.key==='Escape') collapseAllAddBtns();
      });

      document.addEventListener('click',(e)=>{
        if(!e.target.closest('.add-btn')) collapseAllAddBtns();
      });

      document.addEventListener('focusout',(e)=>{
        requestAnimationFrame(()=>{
          if(!document.activeElement||!document.activeElement.closest('.add-btn')){
            collapseAllAddBtns();
          }
        });
      });

      navigate('search');

      const savedCookie=localStorage.getItem('qqmusic_cookie');
      if(savedCookie){
        Api.verifyCookie(savedCookie).then(()=>{
          localStorage.setItem('qqmusic_cookie_status','valid');
          updateCookieStatus('valid');
        }).catch(()=>{
          localStorage.setItem('qqmusic_cookie_status','invalid');
          updateCookieStatus('invalid');
          showToast('Cookie 已失效，请在设置中重新配置','error');
        });
      }

      const savedNeteaseCookie=localStorage.getItem('netease_cookie');
      if(savedNeteaseCookie){
        Api.verifyNeteaseCookie(savedNeteaseCookie).then(()=>{
          localStorage.setItem('netease_cookie_status','valid');
          updateNeteaseCookieStatus('valid');
        }).catch(()=>{
          localStorage.setItem('netease_cookie_status','invalid');
          updateNeteaseCookieStatus('invalid');
        });
      }

      Player.setOnEnded((action)=>{
        if(!Player.currentSong) return;
        let nextSong=null;
        if(Player.playMode==='shuffle'){
          if(action==='next'||action==='random'){
            nextSong=getNextShuffleSong();
          } else if(action==='prev'){
            nextSong=getPrevShuffleSong();
          }
        } else {
          const idx=state.songs.findIndex(s=>s.mid===Player.currentSong.mid);
          if(idx<0) return;
          if(action==='next'){
            const nextIdx=idx+1;
            if(nextIdx<state.songs.length){
              nextSong=state.songs[nextIdx];
            } else if(Player.playMode==='repeat-all'){
              nextSong=state.songs[0];
            }
          } else if(action==='prev'){
            const prevIdx=idx-1;
            if(prevIdx>=0){
              nextSong=state.songs[prevIdx];
            } else if(Player.playMode==='repeat-all'){
              nextSong=state.songs[state.songs.length-1];
            }
          }
        }
        if(nextSong) App.playSong(nextSong.mid, false);
      });
    }
  };

  window.App=App;
  document.addEventListener('DOMContentLoaded',()=>App.init());
})();
