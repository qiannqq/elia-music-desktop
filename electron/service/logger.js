'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

class FileLogger {
  constructor() {
    this._logDir = null;
    this._stream = null;
    this._currentDate = null;
  }

  _resolveLogDir() {
    const isLocal = process.argv.includes('--env=local');

    if (isLocal) {
      return path.join(process.cwd(), 'logs');
    }

    let app;
    try {
      app = require('electron').app;
    } catch (e) {
      console.error('[FileLogger] require electron.app failed:', e.message);
      return path.join(os.tmpdir(), 'qqmusic-logs');
    }

    try {
      const userData = app.getPath('userData');
      return path.join(userData, 'logs');
    } catch (e) {
      console.error('[FileLogger] app.getPath(userData) failed:', e.message);
      return path.join(os.tmpdir(), 'qqmusic-logs');
    }
  }

  _getLogDir() {
    if (this._logDir) return this._logDir;

    const dir = this._resolveLogDir();

    try {
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      this._logDir = dir;
      console.log('[FileLogger] Log dir:', dir);
      return dir;
    } catch (e) {
      console.error('[FileLogger] mkdir failed:', dir, e.message);
    }

    const fallback = path.join(os.tmpdir(), 'qqmusic-logs');
    try {
      if (!fs.existsSync(fallback)) {
        fs.mkdirSync(fallback, { recursive: true });
      }
      this._logDir = fallback;
      console.log('[FileLogger] Log dir (fallback):', fallback);
      return fallback;
    } catch (e) {
      console.error('[FileLogger] fallback mkdir failed:', fallback, e.message);
    }

    return null;
  }

  _getTimeStr() {
    const now = new Date();
    const h = String(now.getHours()).padStart(2, '0');
    const m = String(now.getMinutes()).padStart(2, '0');
    const s = String(now.getSeconds()).padStart(2, '0');
    const ms = String(now.getMilliseconds()).padStart(3, '0');
    return `${h}:${m}:${s}.${ms}`;
  }

  _getDateStr() {
    const now = new Date();
    const y = now.getFullYear();
    const mo = String(now.getMonth() + 1).padStart(2, '0');
    const d = String(now.getDate()).padStart(2, '0');
    return `${y}-${mo}-${d}`;
  }

  _write(level, category, message) {
    const logDir = this._getLogDir();
    if (!logDir) return;

    const dateStr = this._getDateStr();

    if (!this._stream || this._currentDate !== dateStr) {
      if (this._stream) {
        try { this._stream.end(); } catch (e) { /* ignore */ }
      }
      const logFile = path.join(logDir, `${dateStr}.log`);
      try {
        this._stream = fs.createWriteStream(logFile, { flags: 'a', encoding: 'utf-8' });
        this._currentDate = dateStr;
      } catch (e) {
        console.error('[FileLogger] Cannot open log file:', logFile, e.message);
        this._stream = null;
        return;
      }
    }

    const time = this._getTimeStr();
    const line = `[${time}] [${level}] [${category}] ${message}\n`;
    try {
      this._stream.write(line);
    } catch (e) {
      console.error('[FileLogger] Write failed:', e.message);
    }
  }

  info(category, message) { this._write('INFO', category, message); }
  warn(category, message) { this._write('WARN', category, message); }
  error(category, message) { this._write('ERROR', category, message); }
  debug(category, message) { this._write('DEBUG', category, message); }

  close() {
    if (this._stream) {
      try { this._stream.end(); } catch (e) { /* ignore */ }
      this._stream = null;
    }
  }
}

const fileLogger = new FileLogger();

module.exports = { fileLogger, FileLogger };
