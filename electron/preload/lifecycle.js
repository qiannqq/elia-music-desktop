'use strict';

const { logger } = require('ee-core/log');
const { getConfig } = require('ee-core/config');
const { getMainWindow } = require('ee-core/electron');
const { ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const { httpServerService } = require('../service/httpserver');
const { fileLogger } = require('../service/logger');

class Lifecycle {
  async ready() {
    logger.info('[lifecycle] ready');
    fileLogger.info('Lifecycle', 'ready');
  }

  async electronAppReady() {
    logger.info('[lifecycle] electron-app-ready');
    fileLogger.info('Lifecycle', 'electron-app-ready');
    const config = getConfig();
    const port = config.httpServer?.port || 17071;
    httpServerService.start(port);
    this._registerIPC();
  }

  async windowReady() {
    logger.info('[lifecycle] window-ready');
    fileLogger.info('Lifecycle', 'window-ready');
    const config = getConfig();
    const port = config.httpServer?.port || 17071;
    const win = getMainWindow();
    if (win) {
      const http = require('http');
      let ready = false;
      for (let i = 0; i < 50; i++) {
        try {
          await new Promise((resolve, reject) => {
            const req = http.get(`http://127.0.0.1:${port}/api/cookie-status`, { timeout: 500 }, (res) => { res.resume(); resolve(); });
            req.on('error', reject);
            req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
          });
          ready = true;
          break;
        } catch (e) { await new Promise(r => setTimeout(r, 100)); }
      }
      logger.info('[lifecycle] HTTP server ready: %s', ready);
      fileLogger.info('Lifecycle', `HTTP server ready: ${ready}`);

      if (ready) {
        const appUrl = `http://127.0.0.1:${port}`;
        logger.info('[lifecycle] Loading from HTTP: %s', appUrl);
        fileLogger.info('Lifecycle', `Loading from HTTP: ${appUrl}`);
        await win.loadURL(appUrl);
      } else {
        const indexPath = require('path').join(require('ee-core/ps').getBaseDir(), 'public', 'dist', 'index.html');
        logger.info('[lifecycle] HTTP not ready, loading from file: %s', indexPath);
        fileLogger.warn('Lifecycle', `HTTP not ready, loading from file: ${indexPath}`);
        await win.loadFile(indexPath);
      }

      win.show();
      win.focus();
    }
  }

  async beforeClose() {
    logger.info('[lifecycle] before-close');
    fileLogger.info('Lifecycle', 'before-close');
    httpServerService.stop();
    fileLogger.close();
  }

  _registerIPC() {
    ipcMain.handle('win:minimize', () => {
      const win = getMainWindow();
      if (win) win.minimize();
    });

    ipcMain.handle('win:maximize', () => {
      const win = getMainWindow();
      if (win) {
        if (win.isMaximized()) win.unmaximize();
        else win.maximize();
      }
    });

    ipcMain.handle('win:close', () => {
      const win = getMainWindow();
      if (win) win.close();
    });

    ipcMain.handle('dialog:selectDirectory', async () => {
      const win = getMainWindow();
      const result = await dialog.showOpenDialog(win, {
        properties: ['openDirectory'],
        title: '选择保存目录'
      });
      if (result.canceled || !result.filePaths.length) return null;
      return result.filePaths[0];
    });

    ipcMain.handle('fs:saveFile', async (event, filePath, data) => {
      try {
        const dir = path.dirname(filePath);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data);
        fs.writeFileSync(filePath, buffer);
        fileLogger.info('FS', `Saved file: ${filePath} (${buffer.length} bytes)`);
        return filePath;
      } catch (err) {
        logger.error('[fs:saveFile] Error:', err);
        fileLogger.error('FS', `Save file failed: ${filePath} - ${err.message}`);
        throw err;
      }
    });
  }
}

Lifecycle.toString = () => '[class Lifecycle]';

module.exports = { Lifecycle };
