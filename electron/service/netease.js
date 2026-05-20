'use strict';

const { logger } = require('ee-core/log');

const SEARCH_URL = 'http://music.163.com/api/cloudsearch/pc';
const SONG_URL_API = 'https://interface3.music.163.com/api/song/enhance/player/url/v1';
const LYRIC_URL = 'https://music.163.com/api/song/lyric';
const PLAYLIST_URL = 'https://music.163.com/api/v6/playlist/detail';
const SONG_DETAIL_URL = 'https://music.163.com/api/v3/song/detail';
const USER_INFO_URL = 'https://interface.music.163.com/api/nuser/account/get';

const WEB_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const ANDROID_UA = 'Dalvik/2.1.0 (Linux; U; Android 12; MI Build/SKQ1.211230.001)';

class NeteaseMusicService {
  constructor() {
    this.cookie = '';
    this.userId = '';
    this.nickname = '';
    this.isVip = false;
  }

  setCookie(cookie) {
    this.cookie = String(cookie || '').replace(/[\r\n\t\x00]/g, '').trim();
    return this;
  }

  async search(keyword, page = 1, pageSize = 30) {
    if (!keyword || !String(keyword).trim()) {
      throw new Error('keyword 不能为空');
    }

    const offset = (pageSize * page) - pageSize;
    const body = `offset=${offset}&limit=${pageSize}&type=1&s=${encodeURIComponent(String(keyword).trim())}`;

    const res = await this._post(SEARCH_URL, body, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': WEB_UA,
      'Referer': 'https://music.163.com/',
      'Cookie': this.cookie
    });

    if (res.code !== 200 || !res.result) {
      return { list: [], total: 0 };
    }

    const songs = res.result.songs || [];
    const total = res.result.songCount || songs.length;

    return {
      list: songs.map(song => this.normalizeSong(song)),
      total
    };
  }

  normalizeSong(data) {
    const artists = Array.isArray(data.ar) ? data.ar : [];
    const artist = artists.map(a => a.name).filter(Boolean).join('/');
    const album = data.al || {};
    const picUrl = album.picUrl ? album.picUrl + '?param=300x300' : '';

    return {
      id: String(data.id),
      mid: String(data.id),
      mediaMid: '',
      name: String(data.name || '').replace(/<\/?em>/g, ''),
      artist,
      pic: picUrl,
      link: `https://music.163.com/#/song?id=${data.id}`,
      source: 'netease',
      fee: data.privilege?.fee || data.fee || 0,
      duration: data.dt || 0,
      album: album.name || '',
      raw: data,
      data
    };
  }

  async getMusicUrl(song, options = {}) {
    const songId = this._getSongId(song);
    if (!songId) {
      throw new Error('song.id 不能为空');
    }

    const quality = options.quality || 'exhigh';

    try {
      const body = `ids=${JSON.stringify([songId])}&level=${quality}&encodeType=mp3`;
      const res = await this._post(SONG_URL_API, body, {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': ANDROID_UA,
        'Cookie': `versioncode=8008070; os=android; channel=xiaomi; appver=8.8.70; ${this.cookie}`
      });

      if (res.code === 200 && res.data && res.data[0] && res.data[0].url) {
        return res.data[0].url;
      }
    } catch (err) {
      logger.error('[Netease] getMusicUrl API error:', err.message);
    }

    return `https://music.163.com/song/media/outer/url?id=${songId}.mp3`;
  }

  async getLyric(song) {
    const songId = this._getSongId(song);
    if (!songId) {
      throw new Error('song.id 不能为空');
    }

    const url = `${LYRIC_URL}?id=${songId}&lv=-1&tv=-1`;

    try {
      const res = await this._get(url, {
        'User-Agent': WEB_UA,
        'Referer': 'https://music.163.com/',
        'Cookie': this.cookie
      });

      if (res.code === 200) {
        const lrc = res.lrc?.lyric || '';
        const tlyric = res.tlyric?.lyric || '';
        return {
          lyric: lrc,
          trans: tlyric,
          raw: res
        };
      }
    } catch (err) {
      logger.error('[Netease] getLyric error:', err.message);
    }

    return { lyric: '', trans: '', raw: null };
  }

  async getPlaylist(playlistId) {
    if (!playlistId) {
      throw new Error('playlistId 不能为空');
    }

    const body = `id=${playlistId}&n=100000&s=0`;
    const res = await this._post(PLAYLIST_URL, body, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': WEB_UA,
      'Referer': 'https://music.163.com/',
      'Cookie': this.cookie
    });

    if (res.code !== 200 || !res.playlist) {
      throw new Error('获取歌单失败');
    }

    const playlist = res.playlist;
    const trackIds = (playlist.trackIds || []).map(t => t.id);
    let tracks = playlist.tracks || [];

    if (trackIds.length > 0 && tracks.length < trackIds.length) {
      tracks = await this._batchGetTrackDetails(trackIds);
    }

    const list = tracks.map(track => this.normalizeSong(track));

    return {
      list,
      name: playlist.name || '',
      desc: playlist.description || '',
      pic: playlist.coverImgUrl || '',
      creator: playlist.creator ? {
        userId: playlist.creator.userId,
        nickname: playlist.creator.nickname
      } : null,
      trackCount: playlist.trackCount || list.length,
      playCount: playlist.playCount || 0,
      tags: playlist.tags || []
    };
  }

  async validateCookie() {
    try {
      const info = await this.getUserInfo();
      if (info && info.userId) {
        this.userId = info.userId;
        this.nickname = info.nickname;
        this.isVip = info.isVip;
        return true;
      }
    } catch (err) {
      logger.error('[Netease] validateCookie error:', err.message);
    }
    return false;
  }

  async getUserInfo() {
    const res = await this._get(USER_INFO_URL, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': WEB_UA,
      'Cookie': this.cookie
    });

    if (res.code === 200 && res.profile) {
      return {
        userId: res.profile.userId,
        nickname: res.profile.nickname,
        avatarUrl: res.profile.avatarUrl || '',
        isVip: (res.account?.vipType || 0) !== 0
      };
    }

    return null;
  }

  async _batchGetTrackDetails(trackIds) {
    const batchSize = 100;
    const allTracks = [];

    for (let i = 0; i < trackIds.length; i += batchSize) {
      const batch = trackIds.slice(i, i + batchSize);
      const c = batch.map(id => ({ id }));

      try {
        const body = `c=${JSON.stringify(c)}`;
        const res = await this._post(SONG_DETAIL_URL, body, {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': WEB_UA,
          'Referer': 'https://music.163.com/',
          'Cookie': this.cookie
        });

        if (res.code === 200 && res.songs) {
          allTracks.push(...res.songs);
        }
      } catch (err) {
        logger.error('[Netease] batchGetTrackDetails error:', err.message);
      }

      if (i + batchSize < trackIds.length) {
        await new Promise(resolve => setTimeout(resolve, 200));
      }
    }

    return allTracks;
  }

  static extractPlaylistId(url) {
    const match = String(url).match(/[?&]id=(\d+)/);
    return match ? match[1] : null;
  }

  static extractSongId(url) {
    const match = String(url).match(/[?&]id=(\d+)/);
    return match ? match[1] : null;
  }

  _getSongId(song) {
    if (typeof song === 'string') return song;
    return song?.id || song?.mid || song?.raw?.id || song?.data?.id || '';
  }

  async _post(url, body, headers = {}) {
    for (let i = 0; i < 3; i++) {
      try {
        const response = await fetch(url, {
          method: 'POST',
          headers,
          body
        });

        if (!response.ok) {
          throw new Error(`网易云接口请求失败：${response.status} ${response.statusText}`);
        }

        return await response.json();
      } catch (err) {
        if (i < 2) await new Promise(r => setTimeout(r, 500 * (i + 1)));
        else throw err;
      }
    }
  }

  async _get(url, headers = {}) {
    for (let i = 0; i < 3; i++) {
      try {
        const response = await fetch(url, {
          method: 'GET',
          headers
        });

        if (!response.ok) {
          throw new Error(`网易云接口请求失败：${response.status} ${response.statusText}`);
        }

        return await response.json();
      } catch (err) {
        if (i < 2) await new Promise(r => setTimeout(r, 500 * (i + 1)));
        else throw err;
      }
    }
  }
}

NeteaseMusicService.toString = () => '[class NeteaseMusicService]';

module.exports = {
  NeteaseMusicService,
  neteaseMusicService: new NeteaseMusicService()
};
