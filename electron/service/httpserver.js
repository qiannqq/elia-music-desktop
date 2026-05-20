'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { logger } = require('ee-core/log');
const { qqMusicService } = require('./qqmusic');
const { neteaseMusicService } = require('./netease');
const { fileLogger } = require('./logger');
const { app } = require('electron');

function getAppRoot() {
  if (process.argv.includes('--env=local')) {
    return process.cwd();
  }
  return app.getAppPath();
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
};

class HttpServerService {
  constructor() {
    this.server = null;
    this.port = 17071;
  }

  start(port) {
    this.port = port || 17071;
    this.server = http.createServer(async (req, res) => {
      const url = new URL(req.url, `http://localhost:${this.port}`);
      const pathname = url.pathname;

      res.setHeader('Access-Control-Allow-Origin', '*');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-QQMusic-Cookie, X-NetEase-Cookie');

      if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
      }

      try {
        if (pathname.startsWith('/api/')) {
          await this._handleApi(req, res, pathname, url);
        } else {
          this._serveStatic(req, res, pathname);
        }
      } catch (error) {
        logger.error('[HTTP] Error:', error);
        fileLogger.error('HTTP', `Error: ${error.message}`);
        if (!res.headersSent) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: error.message }));
        }
      }
    });

    this.server.listen(this.port, '127.0.0.1', () => {
      logger.info(`[HTTP] Server running at http://127.0.0.1:${this.port}`);
      fileLogger.info('HTTP', `Server running at http://127.0.0.1:${this.port}`);
    });
  }

  stop() {
    if (this.server) {
      this.server.close();
      this.server = null;
    }
  }

  _serveStatic(req, res, pathname) {
    let filePath = pathname;
    if (filePath === '/') filePath = '/index.html';

    const distDir = path.join(getAppRoot(), 'public', 'dist');
    const fullPath = path.join(distDir, filePath);

    const resolved = path.resolve(fullPath);
    if (!resolved.startsWith(path.resolve(distDir))) {
      res.writeHead(403);
      res.end('Forbidden');
      return;
    }

    if (!fs.existsSync(resolved)) {
      res.writeHead(404);
      res.end('Not Found');
      return;
    }

    const stat = fs.statSync(resolved);
    if (stat.isDirectory()) {
      const indexPath = path.join(resolved, 'index.html');
      if (fs.existsSync(indexPath)) {
        return this._serveFile(res, indexPath);
      }
      res.writeHead(404);
      res.end('Not Found');
      return;
    }

    this._serveFile(res, resolved);
  }

  _serveFile(res, filePath) {
    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME[ext] || 'application/octet-stream';
    const content = fs.readFileSync(filePath);
    res.writeHead(200, { 'Content-Type': contentType, 'Cache-Control': 'no-cache' });
    res.end(content);
  }

  _getCookiesFromReq(req) {
    const cookie = req.headers['x-qqmusic-cookie'] || '';
    if (cookie) qqMusicService.setCookie(cookie);
    return cookie;
  }

  _getNeteaseCookiesFromReq(req) {
    const cookie = req.headers['x-netease-cookie'] || '';
    if (cookie) neteaseMusicService.setCookie(cookie);
    return cookie;
  }

  _getBody(req) {
    return new Promise((resolve, reject) => {
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', () => {
        try { resolve(JSON.parse(body)); } catch (e) { resolve({}); }
      });
      req.on('error', reject);
    });
  }

  async _handleApi(req, res, pathname, url) {
    const handlers = {
      'GET:/api/search': () => this._apiSearch(req, res, url),
      'POST:/api/song/url': () => this._apiSongUrl(req, res),
      'POST:/api/song/batch-url': () => this._apiBatchUrl(req, res),
      'GET:/api/song/detail': () => this._apiSongDetail(req, res, url),
      'GET:/api/song/lyric': () => this._apiLyric(req, res, url),
      'GET:/api/playlist': () => this._apiPlaylist(req, res, url),
      'POST:/api/parse-url': () => this._apiParseUrl(req, res),
      'POST:/api/song/download': () => this._apiDownload(req, res),
      'GET:/api/proxy/image': () => this._apiProxyImage(req, res, url),
      'GET:/api/proxy/audio': () => this._apiProxyAudio(req, res, url),
      'GET:/api/cookie-status': () => this._apiCookieStatus(req, res),
      'POST:/api/set-cookie': () => this._apiSetCookie(req, res),
      'GET:/api/download': () => this._apiLegacyDownload(req, res, url),
      'POST:/api/log': () => this._apiLog(req, res),
      'GET:/api/netease/search': () => this._apiNeteaseSearch(req, res, url),
      'POST:/api/netease/song/url': () => this._apiNeteaseSongUrl(req, res),
      'GET:/api/netease/song/lyric': () => this._apiNeteaseLyric(req, res, url),
      'GET:/api/netease/playlist': () => this._apiNeteasePlaylist(req, res, url),
      'POST:/api/netease/validate-cookie': () => this._apiNeteaseValidateCookie(req, res),
      'GET:/api/netease/userinfo': () => this._apiNeteaseUserInfo(req, res),
      'POST:/api/netease/set-cookie': () => this._apiNeteaseSetCookie(req, res),
    };

    const key = `${req.method}:${pathname}`;
    const handler = handlers[key];
    if (handler) {
      await handler();
    } else {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Not Found' }));
    }
  }

  _json(res, data, status) {
    res.writeHead(status || 200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
  }

  async _apiSearch(req, res, url) {
    this._getCookiesFromReq(req);
    const keyword = url.searchParams.get('keyword');
    const page = parseInt(url.searchParams.get('page') || '1');
    const pageSize = parseInt(url.searchParams.get('pageSize') || '50');
    const result = await qqMusicService.search(keyword, page, pageSize);
    this._json(res, { code: 0, data: result.list, total: result.total });
  }

  async _apiSongUrl(req, res) {
    this._getCookiesFromReq(req);
    this._getNeteaseCookiesFromReq(req);
    const url = new URL(req.url, `http://localhost:${this.port}`);
    const mid = url.searchParams.get('mid');
    const hq = url.searchParams.get('highQuality') === 'true';
    const body = await this._getBody(req);
    let songData = { mid, raw: {} };
    if (body.song) songData = body.song;

    let playUrl;
    if (songData.source === 'netease') {
      playUrl = await neteaseMusicService.getMusicUrl(songData, { quality: hq ? 'exhigh' : 'standard' });
    } else {
      playUrl = await qqMusicService.getMusicUrl(songData, { highQuality: hq });
    }
    this._json(res, { code: 0, data: { url: playUrl, mid } });
  }

  async _apiBatchUrl(req, res) {
    this._getCookiesFromReq(req);
    this._getNeteaseCookiesFromReq(req);
    const body = await this._getBody(req);
    const { songs, highQuality } = body;
    const results = await Promise.all(songs.map(async (song) => {
      try {
        let url;
        if (song.source === 'netease') {
          url = await neteaseMusicService.getMusicUrl(song, { quality: highQuality ? 'exhigh' : 'standard' });
        } else {
          url = await qqMusicService.getMusicUrl(song, { highQuality });
        }
        return { ...song, url, success: true };
      } catch (err) {
        return { ...song, url: '', success: false, error: err.message };
      }
    }));
    this._json(res, { code: 0, data: results });
  }

  async _apiSongDetail(req, res, url) {
    this._getCookiesFromReq(req);
    const mid = url.searchParams.get('mid');
    const hq = url.searchParams.get('highQuality') === 'true';
    const song = await qqMusicService.getFirstSong(mid, { pageSize: 1 });
    if (!song) return this._json(res, { error: '歌曲不存在' }, 404);
    const playUrl = await qqMusicService.getMusicUrl(song, { highQuality: hq });
    this._json(res, { code: 0, data: { ...song, url: playUrl } });
  }

  async _apiLyric(req, res, url) {
    this._getCookiesFromReq(req);
    this._getNeteaseCookiesFromReq(req);
    const mid = url.searchParams.get('mid');
    const source = url.searchParams.get('source') || 'qq';
    let lyric;
    if (source === 'netease') {
      lyric = await neteaseMusicService.getLyric(mid);
    } else {
      lyric = await qqMusicService.getLyric(mid);
    }
    this._json(res, { code: 0, data: lyric });
  }

  async _apiPlaylist(req, res, url) {
    this._getCookiesFromReq(req);
    const id = url.searchParams.get('id');
    const data = await qqMusicService.getPlaylist(id);
    this._json(res, { code: 0, data });
  }

  async _apiParseUrl(req, res) {
    const body = await this._getBody(req);
    const inputUrl = (body.url || '').trim();
    if (!inputUrl) return this._json(res, { error: 'URL 不能为空' }, 400);

    const patterns = {
      playlist: [/playlist\/(\d+)/, /[?&]id=(\d+)/],
      song: [/song\/(\w+)\.html/, /song\/(\w+)$/],
      album: [/album\/(\w+)\.html/, /album\/(\w+)$/],
    };

    for (const [type, regs] of Object.entries(patterns)) {
      for (const re of regs) {
        const m = inputUrl.match(re);
        if (m && m[1]) return this._json(res, { code: 0, data: { type, id: m[1] } });
      }
    }
    if (/^\d+$/.test(inputUrl)) return this._json(res, { code: 0, data: { type: 'playlist', id: inputUrl } });
    this._json(res, { error: '无法识别的 URL 格式' }, 400);
  }

  async _apiDownload(req, res) {
    this._getCookiesFromReq(req);
    this._getNeteaseCookiesFromReq(req);
    const body = await this._getBody(req);
    const { song, filename } = body;
    let playUrl;
    if (song.source === 'netease') {
      playUrl = await neteaseMusicService.getMusicUrl(song, { quality: 'exhigh' });
    } else {
      playUrl = await qqMusicService.getMusicUrl(song, { highQuality: true });
    }
    if (!playUrl) return this._json(res, { error: '无法获取播放链接' }, 500);
    this._json(res, { code: 0, data: { url: playUrl, filename: filename || `${song.name} - ${song.artist}.mp3` } });
  }

  async _apiProxyImage(req, res, url) {
    try {
      const rawUrl = url.searchParams.get('url');
      if (!rawUrl) { res.writeHead(400); res.end(); return; }
      const targetUrl = decodeURIComponent(rawUrl);
      logger.info('[ImageProxy] Fetching: %s', targetUrl.substring(0, 120));

      const isNetease = targetUrl.includes('music.126.net') || targetUrl.includes('music.163.com');
      const referer = isNetease ? 'https://music.163.com/' : 'https://y.qq.com/';

      const response = await fetch(targetUrl, {
        headers: {
          'Referer': referer,
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'image/webp,image/apng,image/*,*/*;q=0.8'
        },
        redirect: 'follow'
      });
      logger.info('[ImageProxy] Response: %d %s', response.status, response.headers.get('content-type'));
      if (!response.ok) {
        logger.error('[ImageProxy] Failed: %d', response.status);
        res.writeHead(response.status);
        res.end();
        return;
      }
      res.setHeader('Content-Type', response.headers.get('content-type') || 'image/jpeg');
      res.setHeader('Cache-Control', 'public, max-age=86400');
      res.setHeader('Access-Control-Allow-Origin', '*');
      const cl = response.headers.get('content-length');
      if (cl) res.setHeader('Content-Length', cl);
      const reader = response.body.getReader();
      let total = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(Buffer.from(value));
        total += value.length;
      }
      res.end();
      logger.info('[ImageProxy] Done: %d bytes', total);
    } catch (err) {
      logger.error('[ImageProxy] Error: %s', err.message);
      res.writeHead(500);
      res.end();
    }
  }

  async _apiProxyAudio(req, res, url) {
    const rawUrl = url.searchParams.get('url');
    if (!rawUrl) {
      fileLogger.error('AudioProxy', 'Missing url parameter');
      res.writeHead(400); res.end(); return;
    }
    const targetUrl = decodeURIComponent(rawUrl);
    this._getCookiesFromReq(req);

    const rangeHeader = req.headers.range;
    fileLogger.info('AudioProxy', `Fetching: ${targetUrl.substring(0, 200)} range=${rangeHeader||'none'}`);
    try {
      const isNetease = targetUrl.includes('music.126.net') || targetUrl.includes('music.163.com');
      const referer = isNetease ? 'https://music.163.com/' : 'https://y.qq.com/';
      const cookie = isNetease ? neteaseMusicService.cookie : qqMusicService.cookie;

      const fetchHeaders = {
        'Referer': referer,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Cookie': cookie
      };
      if (rangeHeader) fetchHeaders['Range'] = rangeHeader;

      const response = await fetch(targetUrl, {
        headers: fetchHeaders,
        redirect: 'follow'
      });
      const ct = response.headers.get('content-type') || '';
      const cl = response.headers.get('content-length');
      const cr = response.headers.get('content-range');
      fileLogger.info('AudioProxy', `Response: ${response.status} ${ct} ${cl||'chunked'} rng=${cr||'none'}`);

      if (response.status !== 200 && response.status !== 206) {
        let errBody = '';
        try { errBody = await response.text(); } catch (e) { /* ignore */ }
        fileLogger.error('AudioProxy', `Failed: HTTP ${response.status} ct=${ct} body=${errBody.substring(0, 200)}`);
        res.writeHead(response.status); res.end(); return;
      }

      if (response.status !== 206 && !ct.includes('audio') && !ct.includes('octet-stream') && !ct.includes('mpeg')) {
        let warnBody = '';
        try { warnBody = await response.text(); } catch (e) { /* ignore */ }
        fileLogger.error('AudioProxy', `Non-audio Content-Type: ${ct} body=${warnBody.substring(0, 300)}`);
        res.writeHead(415); res.end(); return;
      }

      const headers = {
        'Content-Type': ct || 'audio/mpeg',
        'Accept-Ranges': 'bytes',
        'Access-Control-Allow-Origin': '*'
      };
      if (response.status === 206) {
        if (cr) headers['Content-Range'] = cr;
        if (cl) headers['Content-Length'] = cl;
        res.writeHead(206, headers);
      } else {
        if (cl) headers['Content-Length'] = cl;
        res.writeHead(200, headers);
      }

      const reader = response.body.getReader();
      let total = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(Buffer.from(value));
        total += value.length;
      }
      res.end();
      fileLogger.info('AudioProxy', `Done: ${total} bytes`);
    } catch (err) {
      fileLogger.error('AudioProxy', `Error: ${err.message}`);
      res.writeHead(500); res.end();
    }
  }

  async _apiCookieStatus(req, res) {
    const hasCookie = qqMusicService.cookie && qqMusicService.cookie.length > 0;
    let isValid = false;
    if (hasCookie) { try { isValid = await qqMusicService.validateCookie(); } catch (e) { /* */ } }
    this._json(res, { code: 0, data: { hasCookie, isValid, needClientCookie: !isValid } });
  }

  async _apiSetCookie(req, res) {
    const body = await this._getBody(req);
    if (!body.cookie) return this._json(res, { error: 'cookie 不能为空' }, 400);
    qqMusicService.setCookie(body.cookie);
    const isValid = await qqMusicService.validateCookie();
    this._json(res, { code: 0, data: { isValid } });
  }

  async _apiLegacyDownload(req, res, url) {
    this._getCookiesFromReq(req);
    const targetUrl = decodeURIComponent(url.searchParams.get('url'));
    const filename = url.searchParams.get('filename');
    const response = await fetch(targetUrl, {
      headers: { 'Referer': 'https://y.qq.com/', 'User-Agent': 'Mozilla/5.0', 'Cookie': qqMusicService.cookie },
      redirect: 'follow'
    });
    if (!response.ok) return this._json(res, { error: `获取音频失败: ${response.status}` }, 500);
    const safeFilename = filename || 'download.mp3';
    const encodedFilename = encodeURIComponent(safeFilename);
    const asciiFilename = safeFilename.replace(/[^\x20-\x7E]/g, '_');
    res.setHeader('Content-Disposition', `attachment; filename="${asciiFilename}"; filename*=UTF-8''${encodedFilename}`);
    res.setHeader('Content-Type', response.headers.get('content-type') || 'audio/mpeg');
    const reader = response.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      res.write(Buffer.from(value));
    }
    res.end();
  }

  async _apiLog(req, res) {
    const body = await this._getBody(req);
    const level = body.level || 'error';
    const message = body.message || '';
    const stack = body.stack || '';
    const url = body.url || '';
    const line = body.line || '';
    const col = body.col || '';

    const prefix = `[Renderer ${level.toUpperCase()}]`;
    const location = url ? ` (${url}${line ? ':' + line : ''}${col ? ':' + col : ''})` : '';
    const fullMsg = `${prefix} ${message}${location}`;
    logger.error(fullMsg);
    if (stack) logger.error(`${prefix} Stack: ${stack}`);

    fileLogger.error('Renderer', message + location);
    if (stack) fileLogger.error('Renderer', 'Stack: ' + stack);

    this._json(res, { code: 0 });
  }

  async _apiNeteaseSearch(req, res, url) {
    this._getNeteaseCookiesFromReq(req);
    const keyword = url.searchParams.get('keyword');
    const page = parseInt(url.searchParams.get('page') || '1');
    const pageSize = parseInt(url.searchParams.get('pageSize') || '30');
    const result = await neteaseMusicService.search(keyword, page, pageSize);
    this._json(res, { code: 0, data: result.list, total: result.total });
  }

  async _apiNeteaseSongUrl(req, res) {
    this._getNeteaseCookiesFromReq(req);
    const body = await this._getBody(req);
    const { song, quality } = body;
    if (!song || !song.id) return this._json(res, { error: 'song.id 不能为空' }, 400);
    const url = await neteaseMusicService.getMusicUrl(song, { quality: quality || 'exhigh' });
    this._json(res, { code: 0, data: { url, id: song.id } });
  }

  async _apiNeteaseLyric(req, res, url) {
    this._getNeteaseCookiesFromReq(req);
    const id = url.searchParams.get('id');
    if (!id) return this._json(res, { error: 'id 不能为空' }, 400);
    const lyric = await neteaseMusicService.getLyric(id);
    this._json(res, { code: 0, data: lyric });
  }

  async _apiNeteasePlaylist(req, res, url) {
    this._getNeteaseCookiesFromReq(req);
    const id = url.searchParams.get('id');
    if (!id) return this._json(res, { error: 'id 不能为空' }, 400);
    const data = await neteaseMusicService.getPlaylist(id);
    this._json(res, { code: 0, data });
  }

  async _apiNeteaseValidateCookie(req, res) {
    const body = await this._getBody(req);
    const cookie = body.cookie || '';
    if (!cookie) return this._json(res, { error: 'cookie 不能为空' }, 400);
    neteaseMusicService.setCookie(cookie);
    const isValid = await neteaseMusicService.validateCookie();
    this._json(res, { code: 0, data: { isValid } });
  }

  async _apiNeteaseUserInfo(req, res) {
    this._getNeteaseCookiesFromReq(req);
    const info = await neteaseMusicService.getUserInfo();
    this._json(res, { code: 0, data: info });
  }

  async _apiNeteaseSetCookie(req, res) {
    const body = await this._getBody(req);
    if (!body.cookie) return this._json(res, { error: 'cookie 不能为空' }, 400);
    neteaseMusicService.setCookie(body.cookie);
    const isValid = await neteaseMusicService.validateCookie();
    this._json(res, { code: 0, data: { isValid } });
  }
}

HttpServerService.toString = () => '[class HttpServerService]';

module.exports = {
  HttpServerService,
  httpServerService: new HttpServerService()
};
