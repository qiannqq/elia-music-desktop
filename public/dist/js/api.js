(function(){
  'use strict';

  const BASE='http://127.0.0.1:17071';

  function sanitizeCookie(raw){
    return String(raw||'').replace(/[\r\n\t\x00]/g,'').trim();
  }

  function getCookie(){
    return sanitizeCookie(localStorage.getItem('qqmusic_cookie'));
  }

  function buildHeaders(extra){
    const h={'Content-Type':'application/json'};
    const c=getCookie();
    if(c) h['X-QQMusic-Cookie']=c;
    if(extra) Object.assign(h,extra);
    return h;
  }

  async function request(url,opts){
    const h=buildHeaders(opts&&opts.headers);
    const merged={};
    for(const k in h){if(h[k]!==undefined&&h[k]!==null) merged[k]=h[k];}
    const resp=await fetch(url,{...opts,headers:merged});
    if(!resp.ok){
      const err=await resp.json().catch(()=>({error:'请求失败'}));
      throw new Error(err.error||'请求失败: '+resp.status);
    }
    return resp.json();
  }

  function enc(v){return encodeURIComponent(String(v||''));}

  const api={
    search(keyword,page,pageSize){
      if(!keyword) return Promise.reject(new Error('keyword 不能为空'));
      page=page||1;pageSize=pageSize||20;
      return request(BASE+'/api/search?keyword='+enc(keyword)+'&page='+page+'&pageSize='+pageSize);
    },
    getSongUrl(mid,highQuality,songData){
      if(!mid) return Promise.reject(new Error('mid 不能为空'));
      let url=BASE+'/api/song/url?mid='+enc(mid)+'&highQuality='+!!highQuality;
      if(songData) return request(url,{method:'POST',body:JSON.stringify({song:songData})});
      return request(url,{method:'POST',body:'{}'});
    },
    getBatchUrls(songs,highQuality){
      if(!songs||!songs.length) return Promise.reject(new Error('songs 不能为空'));
      return request(BASE+'/api/song/batch-url',{method:'POST',body:JSON.stringify({songs,highQuality:!!highQuality})});
    },
    getSongDetail(mid,highQuality){
      if(!mid) return Promise.reject(new Error('mid 不能为空'));
      return request(BASE+'/api/song/detail?mid='+enc(mid)+'&highQuality='+!!highQuality);
    },
    getLyric(mid){
      if(!mid) return Promise.reject(new Error('mid 不能为空'));
      return request(BASE+'/api/song/lyric?mid='+enc(mid));
    },
    getPlaylist(id){
      if(!id) return Promise.reject(new Error('id 不能为空'));
      return request(BASE+'/api/playlist?id='+enc(id));
    },
    parseUrl(url){
      return request(BASE+'/api/parse-url',{method:'POST',body:JSON.stringify({url})});
    },
    setCookie(cookie){
      return request(BASE+'/api/set-cookie',{method:'POST',body:JSON.stringify({cookie:sanitizeCookie(cookie)})});
    },
    getCookieStatus(){
      return request(BASE+'/api/cookie-status');
    }
  };

  function getProxyImageUrl(url){
    if(!url) return '';
    if(url.startsWith(BASE+'/api/proxy/image')) return url;
    return BASE+'/api/proxy/image?url='+encodeURIComponent(url);
  }

  function getProxyAudioUrl(url){
    if(!url) return '';
    if(url.startsWith(BASE+'/api/proxy/audio')) return url;
    return BASE+'/api/proxy/audio?url='+encodeURIComponent(url);
  }

  async function downloadSong(song,filename){
    if(!song||!song.mid) throw new Error('song.mid 不能为空');
    const hdrs={'Content-Type':'application/json'};
    const c=getCookie();
    if(c) hdrs['X-QQMusic-Cookie']=c;
    const resp=await fetch(BASE+'/api/song/download',{
      method:'POST',
      headers:hdrs,
      body:JSON.stringify({song,filename})
    });
    const data=await resp.json().catch(()=>({error:'下载失败'}));
    if(!resp.ok||data.error) throw new Error(data.error||'下载失败: '+resp.status);
    return data.data;
  }

  async function verifyCookie(cookie){
    const clean=sanitizeCookie(cookie);
    if(!clean) throw new Error('Cookie 不能为空');
    const resp=await fetch(BASE+'/api/song/url?mid=003aCYLn3L8H17&highQuality=true',{
      method:'POST',
      headers:{'Content-Type':'application/json','X-QQMusic-Cookie':clean},
      body:'{}'
    });
    if(!resp.ok){
      const s=resp.status;
      if(s===403) throw new Error('Cookie 已过期或无效');
      if(s===401) throw new Error('Cookie 认证失败');
      if(s===429) throw new Error('请求过于频繁');
      throw new Error('验证失败 ('+s+')');
    }
    const data=await resp.json();
    if(data.data&&data.data.url) return true;
    throw new Error('Cookie 验证未通过');
  }

  window.Api={api,getProxyImageUrl,getProxyAudioUrl,downloadSong,verifyCookie,BASE,sanitizeCookie};
})();
