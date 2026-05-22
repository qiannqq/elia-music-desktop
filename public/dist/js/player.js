(function(){
  'use strict';

  let audio=null;
  let currentSong=null;
  let isPlaying=false;
  let isLoading=false;
  let errorTimeout=null;
  let onTimeUpdateCallback=null;
  let onEndedCallback=null;
  let lyricLines=[];
  let activeLyricIndex=-1;
  let playMode=localStorage.getItem('qqmusic_play_mode')||'repeat-all';
  let playlist=[];
  let isDragging=false;
  let lastLyricTimer=null;
  let retryCount=0;
  let playTimeout=null;
  let lyricLoadGeneration=0;

  const $=id=>document.getElementById(id);
  const MODES=['repeat-all','repeat-one','shuffle'];
  const MODE_LABELS={'repeat-all':'列表循环','repeat-one':'单曲循环','shuffle':'随机播放'};

  function els(){
    return {
      bar:$('player-bar'),
      audio:$('audio-player'),
      cover:$('player-cover'),
      coverWrap:$('player-cover-wrap'),
      coverLoading:$('player-cover-loading'),
      name:$('player-name'),
      nameOverlay:$('player-name-overlay'),
      meta:$('player-meta'),
      lyricContainer:$('player-lyric-container'),
      lyricScroll:$('player-lyric-scroll'),
      playBtn:$('player-play-btn'),
      prevBtn:$('player-prev-btn'),
      nextBtn:$('player-next-btn'),
      modeBtn:$('player-mode-btn'),
      lyricBtn:$('player-lyric-btn'),
      iconPlay:$('icon-play'),
      iconPause:$('icon-pause'),
      progress:$('player-progress'),
      progressFill:$('player-progress-fill'),
      currentTime:$('player-current-time'),
      duration:$('player-duration'),
      volume:$('player-volume'),
      closeBtn:$('player-close-btn'),
      error:$('player-error')
    };
  }

  function formatTime(t){
    if(!t||!isFinite(t)||isNaN(t)) return '0:00';
    const m=Math.floor(t/60);
    const s=Math.floor(t%60);
    return m+':'+(s<10?'0':'')+s;
  }

  function setLoading(v){
    isLoading=v;
    const e=els();
    if(e.coverLoading) e.coverLoading.style.display=v?'':'none';
  }

  function setPlaying(v){
    isPlaying=v;
    const e=els();
    e.iconPlay.style.display=v?'none':'';
    e.iconPause.style.display=v?'':'none';
    if(v){
      e.coverWrap.classList.remove('glow-fadeout');
      e.coverWrap.classList.add('playing');
      e.lyricContainer.classList.remove('paused');
    } else {
      if(e.coverWrap.classList.contains('playing')){
        e.coverWrap.classList.remove('playing');
        e.coverWrap.classList.add('glow-fadeout');
        setTimeout(()=>{e.coverWrap.classList.remove('glow-fadeout');},800);
      }
      e.lyricContainer.classList.add('paused');
    }
    if('mediaSession' in navigator){
      navigator.mediaSession.playbackState=v?'playing':'paused';
    }
  }

  function showError(msg){
    const e=els();
    e.error.textContent=msg;
    e.error.style.display='';
    clearTimeout(errorTimeout);
    errorTimeout=setTimeout(()=>{e.error.style.display='none';},4000);
  }

  function updateModeUI(){
    const e=els();
    MODES.forEach(m=>{
      const icon=$('icon-mode-'+m);
      if(icon) icon.style.display=m===playMode?'':'none';
    });
    e.modeBtn.title=MODE_LABELS[playMode]||'播放模式';
  }

  let onModeChangeCallback=null;

  function cycleMode(){
    const idx=MODES.indexOf(playMode);
    playMode=MODES[(idx+1)%MODES.length];
    localStorage.setItem('qqmusic_play_mode',playMode);
    updateModeUI();
    if(onModeChangeCallback) onModeChangeCallback(playMode);
  }

  function setupMediaSession(){
    if(!('mediaSession' in navigator)) return;
    navigator.mediaSession.setActionHandler('play',()=>togglePlay());
    navigator.mediaSession.setActionHandler('pause',()=>togglePlay());
    navigator.mediaSession.setActionHandler('seekto',(details)=>{
      if(details.seekTime!=null&&audio) audio.currentTime=details.seekTime;
    });
    navigator.mediaSession.setActionHandler('previoustrack',()=>{
      if(onEndedCallback) onEndedCallback('prev');
    });
    navigator.mediaSession.setActionHandler('nexttrack',()=>{
      if(onEndedCallback) onEndedCallback('next');
    });
  }

  function updateMediaMetadata(song){
    if(!('mediaSession' in navigator)) return;
    const artwork=[];
    if(song.pic){
      artwork.push({src:Api.getProxyImageUrl(song.pic),sizes:'150x150',type:'image/jpeg'});
    }
    navigator.mediaSession.metadata=new MediaMetadata({
      title:song.name||'未知歌曲',
      artist:song.artist||'未知歌手',
      album:'Elia Music',
      artwork
    });
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

  async function loadLyrics(song){
    const gen=++lyricLoadGeneration;
    const e=els();
    if(!song||!song.mid){
      e.lyricScroll.innerHTML='';
      lyricLines=[];
      return;
    }
    try{
      const localLrc=localStorage.getItem('custom_lyric_'+song.mid);
      let parsed;
      if(localLrc&&localLrc.trim()){
        parsed=parseLRC(localLrc);
      }else{
        const res=song.source==='netease'
          ?await Api.neteaseApi.getLyric(song.mid)
          :await Api.api.getLyric(song.mid);
        if(gen!==lyricLoadGeneration) return;
        parsed=parseLRC(res.data&&res.data.lyric||'');
      }
      if(gen!==lyricLoadGeneration) return;
      lyricLines=parsed;
      activeLyricIndex=-1;
      let html='';
      if(parsed.length>0){
        parsed.forEach((line,idx)=>{
          html+='<div class="player-lyric-line" data-idx="'+idx+'">'+line.text.replace(/</g,'&lt;').replace(/>/g,'&gt;')+'</div>';
        });
      } else {
        html='<div class="player-lyric-line active">'+(song.name||'-')+'</div>';
      }
      e.lyricScroll.innerHTML=html;
    }catch(err){
      if(gen!==lyricLoadGeneration) return;
      lyricLines=[];
      e.lyricScroll.innerHTML='<div class="player-lyric-line active">'+(song.name||'-')+'</div>';
    }
  }

  function updateLyricScroll(currentTime){
    if(!lyricLines.length) return;
    let idx=-1;
    for(let i=0;i<lyricLines.length;i++){
      if(lyricLines[i].time<=currentTime) idx=i;
      else break;
    }
    if(idx!==activeLyricIndex&&idx>=0){
      activeLyricIndex=idx;
      const e=els();
      const lines=e.lyricScroll.querySelectorAll('.player-lyric-line');
      lines.forEach((el,i)=>{
        el.classList.toggle('active',i===idx);
      });
      const lineHeight=24;
      const offset=-(idx*lineHeight);
      e.lyricScroll.style.transform='translateY('+offset+'px)';

      if(idx===lyricLines.length-1){
        const lastTime=lyricLines[idx].time;
        const remaining=Math.max(0,(audio.duration||0)-lastTime);
        clearTimeout(lastLyricTimer);
        lastLyricTimer=setTimeout(()=>{
          const e2=els();
          if(e2.lyricContainer) e2.lyricContainer.classList.add('paused');
        },5000);
      } else {
        clearTimeout(lastLyricTimer);
        lastLyricTimer=null;
        const e3=els();
        if(isPlaying&&e3.lyricContainer) e3.lyricContainer.classList.remove('paused');
      }

      if(onTimeUpdateCallback) onTimeUpdateCallback(idx,currentTime);
    }
  }

  function play(song){
    if(!song||!song.url) return;
    currentSong=song;
    retryCount=0;
    const e=els();
    e.bar.style.display='flex';
    document.body.classList.add('has-player');

    if(Api.getProxyImageUrl&&song.pic){
      e.cover.innerHTML='<img src="'+Api.getProxyImageUrl(song.pic)+'" alt="">';
    } else {
      e.cover.innerHTML='<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>';
    }

    e.name.textContent=song.name||'-';
    e.name.title=song.name||'-';
    e.name.style.cursor='pointer';
    e.nameOverlay.textContent=song.name||'-';
    updateMediaMetadata(song);

    const proxyUrl=Api.getProxyAudioUrl(song.url);
    e.audio.src=proxyUrl;
    e.audio.load();
    setPlaying(false);
    setLoading(true);
    e.progressFill.style.width='0';
    e.currentTime.textContent='0:00';
    e.duration.textContent='0:00';
    lyricLines=[];
    activeLyricIndex=-1;
    e.lyricScroll.innerHTML='';
    e.lyricScroll.style.transform='translateY(0)';

    loadLyrics(song);

    if(playTimeout) clearTimeout(playTimeout);
    playTimeout=setTimeout(()=>{
      e.audio.play().then(()=>{
        setPlaying(true);
        setLoading(false);
      }).catch(err=>{
        console.error('Auto play failed:',err);
        setLoading(false);
      });
    },100);
  }

  function close(){
    const e=els();
    e.audio.pause();
    e.audio.src='';
    e.bar.style.display='none';
    document.body.classList.remove('has-player');
    setPlaying(false);
    setLoading(false);
    currentSong=null;
    lyricLines=[];
    activeLyricIndex=-1;
  }

  function togglePlay(){
    const e=els();
    if(!e.audio.src) return;
    if(isPlaying){
      e.audio.pause();
      setPlaying(false);
    } else {
      e.audio.play().then(()=>{setPlaying(true);setLoading(false);}).catch(err=>{
        showError('播放失败');
      });
    }
  }

  function seek(percent){
    const e=els();
    if(!isFinite(percent)||percent<0||percent>1) return;
    const dur=e.audio.duration;
    if(!dur||!isFinite(dur)||dur<=0) return;
    e.audio.currentTime=percent*dur;
  }

  function setOnTimeUpdate(cb){
    onTimeUpdateCallback=cb;
  }

  function setOnEnded(cb){
    onEndedCallback=cb;
  }

  function setPlaylist(pl){
    playlist=pl||[];
  }

  function handleEnded(){
    if(playMode==='repeat-one'){
      audio.currentTime=0;
      audio.play().then(()=>setPlaying(true));
      return;
    }
    clearTimeout(lastLyricTimer);
    setPlaying(false);
    setLoading(false);
    const e=els();
    e.progressFill.style.width='0';
    e.currentTime.textContent='0:00';
    if(onEndedCallback){
      if(playMode==='shuffle') onEndedCallback('random');
      else onEndedCallback('next');
    }
  }

  function openLyricModal(){
    if(currentSong&&currentSong.mid&&window.App&&App.viewLyric){
      App.viewLyric(currentSong.mid);
    }
  }

  function init(){
    const e=els();
    audio=e.audio;

    e.audio.addEventListener('timeupdate',()=>{
      if(isDragging) return;
      if(e.audio.duration&&isFinite(e.audio.duration)){
        const pct=(e.audio.currentTime/e.audio.duration)*100;
        e.progressFill.style.width=pct+'%';
        e.currentTime.textContent=formatTime(e.audio.currentTime);
      }
      updateLyricScroll(e.audio.currentTime);
      if('mediaSession' in navigator&&e.audio.duration&&isFinite(e.audio.duration)){
        navigator.mediaSession.setPositionState({
          duration:e.audio.duration,
          playbackRate:e.audio.playbackRate,
          position:e.audio.currentTime
        });
      }
    });

    e.audio.addEventListener('loadedmetadata',()=>{
      if(e.audio.duration&&isFinite(e.audio.duration)){
        e.duration.textContent=formatTime(e.audio.duration);
      }
      setLoading(false);
    });

    e.audio.addEventListener('playing',()=>{
      setPlaying(true);
      setLoading(false);
    });

    e.audio.addEventListener('waiting',()=>{
      setLoading(true);
    });

    e.audio.addEventListener('play',()=>setPlaying(true));
    e.audio.addEventListener('pause',()=>setPlaying(false));
    e.audio.addEventListener('ended',handleEnded);

    e.audio.addEventListener('error',async()=>{
      const mediaError=e.audio.error;
      const errCode=mediaError?mediaError.code:0;
      const errMap={1:'MEDIA_ERR_ABORTED',2:'MEDIA_ERR_NETWORK',3:'MEDIA_ERR_DECODE',4:'MEDIA_ERR_SRC_NOT_SUPPORTED'};
      const errName=errMap[errCode]||'UNKNOWN';
      const src=e.audio.currentSrc||'';

      if(errCode===4&&retryCount<1&&currentSong){
        retryCount++;
        try{
          const res=await Api.api.getSongUrl(currentSong.mid,false,currentSong);
          if(res.data&&res.data.url){
            currentSong.url=res.data.url;
            const newUrl=Api.getProxyAudioUrl(res.data.url);
            e.audio.src=newUrl;
            e.audio.load();
            e.audio.play().then(()=>{setPlaying(true);setLoading(false);retryCount=0;}).catch(()=>{});
            return;
          }
        }catch(ex){}
      }

      showError('音频加载失败 ['+errName+']');
      setPlaying(false);
      setLoading(false);
      try{
        const payload={
          level:'error',
          message:'Audio error: '+errName+' (code='+errCode+') retry='+retryCount+' src='+src,
          stack:'',
          url:src,
          line:'',
          col:''
        };
        navigator.sendBeacon(Api.BASE+'/api/log',JSON.stringify(payload));
      }catch(ex){}
    });

    e.playBtn.addEventListener('click',togglePlay);
    e.prevBtn.addEventListener('click',()=>{
      if(onEndedCallback) onEndedCallback('prev');
    });
    e.nextBtn.addEventListener('click',()=>{
      if(onEndedCallback) onEndedCallback('next');
    });
    e.modeBtn.addEventListener('click',cycleMode);

    if(MODES.indexOf(playMode)<0) playMode='repeat-all';
    updateModeUI();

    e.lyricBtn.addEventListener('click',openLyricModal);
    e.name.addEventListener('click',openLyricModal);
    e.lyricContainer.addEventListener('click',(ev)=>{
      if(ev.target.closest('.player-lyric-btn')) return;
      openLyricModal();
    });

    e.progress.addEventListener('mousedown',(ev)=>{
      if(!audio.duration||!isFinite(audio.duration)) return;
      isDragging=true;
      const rect=e.progress.getBoundingClientRect();
      const pct=Math.max(0,Math.min(1,(ev.clientX-rect.left)/rect.width));
      seek(pct);
      e.progressFill.style.width=(pct*100)+'%';
    });
    document.addEventListener('mousemove',(ev)=>{
      if(!isDragging) return;
      const e=els();
      const rect=e.progress.getBoundingClientRect();
      const pct=Math.max(0,Math.min(1,(ev.clientX-rect.left)/rect.width));
      e.progressFill.style.width=(pct*100)+'%';
      if(audio.duration&&isFinite(audio.duration)){
        e.currentTime.textContent=formatTime(pct*audio.duration);
      }
    });
    document.addEventListener('mouseup',(ev)=>{
      if(!isDragging) return;
      isDragging=false;
      const e=els();
      const rect=e.progress.getBoundingClientRect();
      const pct=Math.max(0,Math.min(1,(ev.clientX-rect.left)/rect.width));
      seek(pct);
    });

    const savedVolume=parseFloat(localStorage.getItem('qqmusic_volume'));
    if(!isNaN(savedVolume)){
      e.audio.volume=savedVolume;
      e.volume.value=savedVolume;
    } else {
      e.audio.volume=0.8;
    }

    function updateVolumeTooltip(){
      const tooltip=$('volume-tooltip');
      if(tooltip) tooltip.textContent=Math.round(e.audio.volume*100)+'%';
    }

    e.volume.addEventListener('input',()=>{
      e.audio.volume=parseFloat(e.volume.value);
      localStorage.setItem('qqmusic_volume',String(e.audio.volume));
      updateVolumeTooltip();
    });

    const volumeWrapper=e.volume.parentElement;
    volumeWrapper.addEventListener('wheel',(ev)=>{
      ev.preventDefault();
      const delta=ev.deltaY<0?0.05:-0.05;
      const newVol=Math.max(0,Math.min(1,e.audio.volume+delta));
      e.audio.volume=newVol;
      e.volume.value=newVol;
      localStorage.setItem('qqmusic_volume',String(newVol));
      updateVolumeTooltip();
    },{passive:false});

    volumeWrapper.addEventListener('mouseenter',updateVolumeTooltip);

    e.closeBtn.addEventListener('click',close);
    setupMediaSession();
  }

  function setOnModeChange(cb){
    onModeChangeCallback=cb;
  }

  window.Player={
    init,play,close,togglePlay,seek,
    setOnTimeUpdate,setOnEnded,setPlaylist,setOnModeChange,
    get currentSong(){return currentSong},
    get isPlaying(){return isPlaying},
    get isLoading(){return isLoading},
    get playMode(){return playMode},
    get currentTime(){return audio?audio.currentTime:0},
    get lyricLines(){return lyricLines},
    getDuration(){return audio&&audio.duration&&isFinite(audio.duration)?audio.duration:NaN}
  };
})();
