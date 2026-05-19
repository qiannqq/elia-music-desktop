'use strict';

const path = require('path');
const { getBaseDir } = require('ee-core/ps');

module.exports = () => {
  return {
    openDevTools: false,
    singleLock: true,
    windowsOption: {
      title: 'Elia Music',
      width: 1100,
      height: 720,
      minWidth: 800,
      minHeight: 560,
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        preload: path.join(getBaseDir(), 'public', 'electron', 'preload', 'bridge.js'),
      },
      frame: false,
      show: false,
      backgroundColor: '#f3f3f3',
      icon: path.join(getBaseDir(), 'public', 'images', 'logo-32.png'),
    },
    logger: {
      level: 'INFO',
      outputJSON: false,
      appLogName: 'qqmusic.log',
      coreLogName: 'qqmusic-core.log',
      errorLogName: 'qqmusic-error.log',
    },
    remote: { enable: false, url: '' },
    socketServer: { enable: false },
    httpServer: {
      enable: false,
      https: { enable: false },
      host: '127.0.0.1',
      port: 17071,
    },
    mainServer: {
      indexPath: '/public/dist/index.html',
      channelSeparator: '/',
    },
  };
};
