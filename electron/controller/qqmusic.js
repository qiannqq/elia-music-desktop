'use strict';

const { logger } = require('ee-core/log');
const { qqMusicService } = require('../service/qqmusic');

/**
 * QQ音乐 API 控制器
 * @class
 */
class QQMusicController {
  /**
   * 搜索歌曲
   */
  async search(args) {
    const { keyword, page = 1, pageSize = 20 } = args;
    if (!keyword) {
      throw new Error('keyword 不能为空');
    }
    const list = await qqMusicService.search(keyword, Number(page), Number(pageSize));
    return { code: 0, data: list };
  }

  /**
   * 获取歌曲URL
   */
  async getSongUrl(args) {
    const { song, highQuality = false } = args;
    if (!song || !song.mid) {
      throw new Error('song.mid 不能为空');
    }
    const url = await qqMusicService.getMusicUrl(song, { highQuality });
    return { code: 0, data: { url, mid: song.mid } };
  }

  /**
   * 批量获取歌曲URL
   */
  async getBatchSongUrl(args) {
    const { songs, highQuality = false } = args;
    if (!Array.isArray(songs) || songs.length === 0) {
      throw new Error('songs 必须是数组且不能为空');
    }
    const results = await Promise.all(
      songs.map(async (song) => {
        try {
          const url = await qqMusicService.getMusicUrl(song, { highQuality });
          return { ...song, url, success: true };
        } catch (err) {
          return { ...song, url: '', success: false, error: err.message };
        }
      })
    );
    return { code: 0, data: results };
  }

  /**
   * 获取歌曲详情
   */
  async getSongDetail(args) {
    const { mid, highQuality = false } = args;
    if (!mid) {
      throw new Error('mid 不能为空');
    }
    const song = await qqMusicService.getFirstSong(mid, { pageSize: 1 });
    if (!song) {
      throw new Error('歌曲不存在');
    }
    const url = await qqMusicService.getMusicUrl(song, { highQuality });
    return { code: 0, data: { ...song, url } };
  }

  /**
   * 获取歌词
   */
  async getLyric(args) {
    const { mid } = args;
    if (!mid) {
      throw new Error('mid 不能为空');
    }
    const lyric = await qqMusicService.getLyric(mid);
    return { code: 0, data: lyric };
  }

  /**
   * 获取歌单
   */
  async getPlaylist(args) {
    const { id } = args;
    if (!id) {
      throw new Error('歌单 ID 不能为空');
    }
    const data = await qqMusicService.getPlaylist(id);
    return { code: 0, data };
  }

  /**
   * 解析URL
   */
  async parseUrl(args) {
    const { url } = args;
    if (!url) {
      throw new Error('URL 不能为空');
    }

    const trimmedUrl = url.trim();

    const playlistPatterns = [
      /playlist\/(\d+)/,
      /[?&]id=(\d+)/,
    ];

    const songPatterns = [
      /song\/(\w+)\.html/,
      /song\/(\w+)$/,
    ];

    const albumPatterns = [
      /album\/(\w+)\.html/,
      /album\/(\w+)$/,
    ];

    for (const pattern of playlistPatterns) {
      const match = trimmedUrl.match(pattern);
      if (match && match[1]) {
        return { code: 0, data: { type: 'playlist', id: match[1] } };
      }
    }

    for (const pattern of songPatterns) {
      const match = trimmedUrl.match(pattern);
      if (match && match[1]) {
        return { code: 0, data: { type: 'song', id: match[1] } };
      }
    }

    for (const pattern of albumPatterns) {
      const match = trimmedUrl.match(pattern);
      if (match && match[1]) {
        return { code: 0, data: { type: 'album', id: match[1] } };
      }
    }

    if (/^\d+$/.test(trimmedUrl)) {
      return { code: 0, data: { type: 'playlist', id: trimmedUrl } };
    }

    throw new Error('无法识别的 URL 格式');
  }

  /**
   * 设置Cookie
   */
  async setCookie(args) {
    const { cookie } = args;
    if (!cookie) {
      throw new Error('cookie 不能为空');
    }
    qqMusicService.setCookie(cookie);
    const isValid = await qqMusicService.validateCookie();
    return { code: 0, data: { isValid } };
  }

  /**
   * 获取Cookie状态
   */
  async getCookieStatus() {
    const hasCookie = qqMusicService.cookie && qqMusicService.cookie.length > 0;
    let isValid = false;
    if (hasCookie) {
      try {
        isValid = await qqMusicService.validateCookie();
      } catch (e) {
        isValid = false;
      }
    }
    return {
      code: 0,
      data: {
        hasCookie,
        isValid,
        needClientCookie: !isValid
      }
    };
  }
}

QQMusicController.toString = () => '[class QQMusicController]';

module.exports = QQMusicController;
