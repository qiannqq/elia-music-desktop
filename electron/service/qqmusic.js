'use strict';

const crypto = require('crypto');
const { logger } = require('ee-core/log');

const MUSICU_URL = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const STREAM_HOST = 'http://ws.stream.qqmusic.qq.com/';
const LYRIC_URL = 'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';

class QQMusicService {
  constructor() {
    this.cookieMap = new Map();
    this.cookie = '';
    this.uin = '0';
    this.guid = this._md5('000000music');
    this.highQuality = false;
  }

  setCookie(cookie) {
    this.cookieMap = QQMusicService.parseCookie(cookie);
    this.cookie = QQMusicService.stringifyCookie(this.cookieMap);
    this.uin = String(this.cookieMap.get('uin') || this.cookieMap.get('wxuin') || this.uin || '0');
    this.guid = this._md5(`${this.uin || '000000'}music`);
    return this;
  }

  async search(keyword, page = 1, pageSize = 10) {
    if (!keyword || !String(keyword).trim()) {
      throw new Error('keyword 不能为空');
    }

    const body = {
      comm: { uin: '0', authst: '', ct: 29 },
      search: {
        method: 'DoSearchForQQMusicMobile',
        module: 'music.search.SearchCgiService',
        param: {
          grp: 1,
          num_per_page: pageSize,
          page_num: page,
          query: String(keyword).trim(),
          remoteplace: 'miniapp.1109523715',
          search_type: 0,
          searchid: String(Math.floor(Math.random() * 10000000))
        }
      }
    };

    const res = await this._requestMusicu(body, {
      'Content-Type': 'application/json',
      'User-Agent': 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)'
    });

    if (!this._isOkCode(res.code)) {
      return [];
    }

    const data = res.search?.data?.body || {};
    const list = data.song?.list || data.item_song || [];
    return list.map(item => this.normalizeSong(item));
  }

  normalizeSong(data) {
    const mid = data.mid || data.songmid || '';
    const singers = Array.isArray(data.singer) ? data.singer : [];
    const artist = singers.map(item => item.name).filter(Boolean).join('/');
    const albumMid = data.album?.mid || '';
    const singerMid = singers[0]?.mid || '';
    const vsPic = data.vs?.[1] || '';
    const picKey = vsPic
      ? `T062R150x150M000${vsPic}`
      : albumMid
        ? `T002R150x150M000${albumMid}`
        : singerMid
          ? `T001R150x150M000${singerMid}`
          : '';

    return {
      id: mid,
      mid,
      mediaMid: data.file?.media_mid || '',
      name: String(data.title || data.name || '').replace(/<\/?em>/g, ''),
      artist,
      pic: picKey ? `http://y.gtimg.cn/music/photo_new/${picKey}.jpg` : '',
      link: mid ? `https://y.qq.com/n/yqq/song/${mid}.html` : '',
      source: 'qq',
      raw: data,
      data
    };
  }

  async getMusicUrl(song, options = {}) {
    const data = this._getRawSong(song);
    const mid = this._getSongMid(song);

    if (!mid) {
      throw new Error('song.mid 不能为空');
    }

    let playUrl = this._createLegacyPlayUrl(mid);
    const highQuality = options.highQuality ?? this.highQuality;
    const needVkey = Boolean(
      options.forceVkey ||
      highQuality ||
      (data.sa === 0 && data.pay?.price_track === 0) ||
      data.pay?.pay_play === 1
    );

    if (!needVkey) {
      return playUrl;
    }

    const result = await this.getVkey(song, { highQuality });
    if (result.url) {
      playUrl = result.url;
    }

    return playUrl;
  }

  async getVkey(song, options = {}) {
    const data = this._getRawSong(song);
    const mid = this._getSongMid(song);

    if (!mid) {
      throw new Error('song.mid 不能为空');
    }

    const param = {
      guid: this._md5(String(Date.now())),
      songmid: [mid],
      songtype: [0],
      uin: this.uin || '0',
      ctx: 1
    };

    if (options.highQuality) {
      const mediaMid = data.file?.media_mid || data.mediaMid || data.strMediaMid || mid;
      const qualityList = [
        ['size_320mp3', 'M800', 'mp3'],
        ['size_192ogg', 'O600', 'ogg'],
        ['size_128mp3', 'M500', 'mp3'],
        ['size_96aac', 'C400', 'm4a']
      ];

      const filename = [];
      const songmid = [];
      const songtype = [];

      for (const quality of qualityList) {
        const [sizeKey, prefix, ext] = quality;
        if (data.file && Number(data.file[sizeKey] || 0) < 1) {
          continue;
        }
        songmid.push(mid);
        songtype.push(0);
        filename.push(`${prefix}${mediaMid}.${ext}`);
      }

      if (filename.length > 0) {
        param.filename = filename;
        param.songmid = songmid;
        param.songtype = songtype;
      }
    }

    const body = {
      comm: this._createQQMusicComm(),
      req_0: {
        module: 'vkey.GetVkeyServer',
        method: 'CgiGetVkey',
        param
      }
    };

    const res = await this._requestMusicu(body, {
      'Content-Type': 'application/x-www-form-urlencoded'
    });

    if (!this._isOkCode(res.req_0?.code)) {
      return { url: '', purl: '', raw: res };
    }

    const midurlinfo = res.req_0?.data?.midurlinfo || [];
    const item = midurlinfo.find(info => info?.purl);
    const purl = item?.purl || '';

    return {
      url: purl ? `${STREAM_HOST}${purl}` : '',
      purl,
      raw: item || res
    };
  }

  async getFirstSong(keyword, options = {}) {
    const list = await this.search(keyword, options.page || 1, options.pageSize || 10);
    const song = list[0];

    if (!song) {
      return null;
    }

    return {
      ...song,
      url: await this.getMusicUrl(song, { highQuality: options.highQuality })
    };
  }

  async getLyric(song) {
    const mid = this._getSongMid(song);

    if (!mid) {
      throw new Error('song.mid 不能为空');
    }

    const url = `${LYRIC_URL}?_=${Date.now()}&cv=4747474&ct=24&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=1&uin=0&g_tk_new_20200303=5381&g_tk=5381&loginUin=0&songmid=${encodeURIComponent(mid)}`;
    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/105.0.0.0 Safari/537.36',
        'Referer': 'https://y.qq.com/',
        'Cookie': this.cookie
      }
    });
    const res = await response.json();

    return {
      lyric: res.lyric ? Buffer.from(res.lyric, 'base64').toString('utf8') : '',
      trans: res.trans ? Buffer.from(res.trans, 'base64').toString('utf8') : '',
      raw: res
    };
  }

  async validateCookie() {
    try {
      const url = `https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg?_=${Date.now()}&cv=4747474&ct=24&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0&uin=0&g_tk_new_20200303=5381&g_tk=5381&cid=205360838&userid=0&reqfrom=1&reqtype=0&hostUin=0&loginUin=0`;
      const response = await fetch(url, {
        method: 'GET',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Cookie': this.cookie,
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        }
      });
      const res = await response.json();
      return res.code === 0 || res.code === '0';
    } catch {
      return false;
    }
  }

  async getPlaylist(id) {
    const body = {
      comm: { uin: '0', authst: '', ct: 29 },
      req_0: {
        module: 'srf_diss_info.DissInfoServer',
        method: 'CgiGetDiss',
        param: {
          disstid: Number(id),
          dirid: 0,
          onlysonglist: 0,
          song_begin: 0,
          song_num: 500,
          userinfo: 1,
          pic_dpi: 800,
          orderlist: 1
        }
      }
    };

    const response = await fetch(MUSICU_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Cookie': this.cookie,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
      },
      body: JSON.stringify(body)
    });

    const data = await response.json();
    if (data.req_0?.code !== 0 && data.req_0?.code !== '0') {
      throw new Error('获取歌单失败');
    }

    const songList = data.req_0?.data?.songlist || [];
    const list = songList.map(item => this.normalizeSong(item));

    return {
      list,
      name: data.req_0?.data?.dirname || '',
      desc: data.req_0?.data?.desc || '',
      pic: data.req_0?.data?.dir_pic_url2 || ''
    };
  }

  static parseCookie(cookie = '') {
    if (cookie instanceof Map) {
      return new Map(cookie);
    }

    if (typeof cookie === 'object' && cookie !== null) {
      return new Map(Object.entries(cookie));
    }

    const map = new Map();
    String(cookie).split(';').forEach(item => {
      const text = item.trim();
      if (!text) {
        return;
      }

      const index = text.indexOf('=');
      if (index < 0) {
        return;
      }

      map.set(text.slice(0, index).trim(), text.slice(index + 1).trim());
    });

    return map;
  }

  static stringifyCookie(cookie = '') {
    if (typeof cookie === 'string') {
      return cookie;
    }

    const map = cookie instanceof Map ? cookie : new Map(Object.entries(cookie || {}));
    return [...map.entries()]
      .filter(([, value]) => value !== undefined && value !== null && value !== '')
      .map(([key, value]) => `${key}=${value}`)
      .join('; ');
  }

  async _requestMusicu(body, headers = {}) {
    let lastErr;
    for (let i = 0; i < 3; i++) {
      try {
        const response = await fetch(MUSICU_URL, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Cookie': this.cookie,
            ...headers
          },
          body: JSON.stringify(body)
        });

        if (!response.ok) {
          throw new Error(`QQ音乐接口请求失败：${response.status} ${response.statusText}`);
        }

        return response.json();
      } catch (err) {
        lastErr = err;
        if (i < 2) await new Promise(r => setTimeout(r, 500 * (i + 1)));
      }
    }
    throw lastErr;
  }

  _createQQMusicComm() {
    const loginType = this.cookieMap.get('wxunionid') ? 1 : Number(this.cookieMap.get('tmeLoginType') || '2');
    const qqUnionId = this.cookieMap.get('psrf_qqunionid') || '';
    const wxUnionId = this.cookieMap.get('wxunionid') || '';

    return {
      _channelid: '19',
      _os_version: '6.2.9200-2',
      authst: this.cookieMap.get('qqmusic_key') || this.cookieMap.get('qm_keyst') || '',
      ct: '19',
      cv: '1891',
      guid: this.guid,
      patch: '118',
      psrf_access_token_expiresAt: Number(this.cookieMap.get('psrf_access_token_expiresAt') || 0),
      psrf_qqaccess_token: this.cookieMap.get('psrf_qqaccess_token') || '',
      psrf_qqopenid: this.cookieMap.get('psrf_qqopenid') || '',
      psrf_qqunionid: qqUnionId || wxUnionId,
      tmeAppID: 'qqmusic',
      tmeLoginType: loginType,
      uin: this.cookieMap.get('uin') || '0',
      wid: this.cookieMap.get('wxuin') || '0'
    };
  }

  _createLegacyPlayUrl(mid) {
    const code = this._md5(`${mid}q;z(&l~sdf2!nK`).substring(0, 5).toUpperCase();
    return `http://c6.y.qq.com/rsc/fcgi-bin/fcg_pyq_play.fcg?songid=&songmid=${encodeURIComponent(mid)}&songtype=1&fromtag=50&uin=${encodeURIComponent(this.uin || '0')}&code=${code}`;
  }

  _getRawSong(song) {
    if (typeof song === 'string') {
      return { mid: song };
    }

    return song?.raw || song?.data || song || {};
  }

  _getSongMid(song) {
    if (typeof song === 'string') {
      return song;
    }

    return song?.mid || song?.id || song?.raw?.mid || song?.data?.mid || '';
  }

  _isOkCode(code) {
    return code === 0 || code === '0';
  }

  _md5(text) {
    return crypto.createHash('md5').update(String(text)).digest('hex');
  }
}

QQMusicService.toString = () => '[class QQMusicService]';

module.exports = {
  QQMusicService,
  qqMusicService: new QQMusicService()
};
