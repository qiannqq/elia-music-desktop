/**
 * ee-bin 配置
 * 仅适用于开发环境
 */
module.exports = {
  /**
   * development serve ("frontend" "electron" )
   * ee-bin dev
   */
  dev: {
    frontend: {
      protocol: 'http://',
      hostname: '127.0.0.1',
      port: 17071,
      indexPath: 'index.html',
      force: true,
    },
    electron: {
      directory: './',
      cmd: 'electron',
      args: ['.', '--env=local'],
      watch: false,
      loadingPage: '',
    }
  },

  /**
   * 构建
   * ee-bin build
   */
  build: {
    electron: {
      type: 'javascript',
      bundleType: 'copy'
    },
    win64: {
      cmd: 'electron-builder',
      directory: './',
      args: ['--config=./cmd/builder.json', '-w=nsis', '--x64'],
    },
    win32: {
      args: ['--config=./cmd/builder.json', '-w=nsis', '--ia32'],
    },
    win_e: {
      args: ['--config=./cmd/builder.json', '-w=portable', '--x64'],
    },
    win_7z: {
      args: ['--config=./cmd/builder.json', '-w=7z', '--x64'],
    },
    mac: {
      args: ['--config=./cmd/builder-mac.json', '-m'],
    },
    mac_arm64: {
      args: ['--config=./cmd/builder-mac-arm64.json', '-m', '--arm64'],
    },
    linux: {
      args: ['--config=./cmd/builder-linux.json', '-l=AppImage', '--x64'],
    },
  },

  /**
   * 移动资源
   * ee-bin move 
   */
  move: {
    frontend_dist: {
      src: './frontend/dist',
      dest: './public/dist'
    },
  },  

  /**
   * 预发布模式（prod）
   * ee-bin start
   */
  start: {
    directory: './',
    cmd: 'electron',
    args: ['.', '--env=prod']
  },

  /**
   * 加密
   */  
  encrypt: {
    frontend: {
      type: 'none',
      files: [
        './public/dist/**/*.(js|json)',
      ],
      cleanFiles: ['./public/dist'],
      confusionOptions: {
        compact: true,      
        stringArray: true,
        stringArrayEncoding: ['none'],
        stringArrayCallsTransform: true,
        numbersToExpressions: true,
        target: 'browser',
      }
    },
    electron: {
      type: 'confusion',
      files: [
        './public/electron/**/*.(js|json)',
      ],
      cleanFiles: ['./public/electron'],
      specificFiles: [
        './public/electron/main.js',
        './public/electron/preload/bridge.js',
      ],
      confusionOptions: {
        compact: true,      
        stringArray: true,
        stringArrayEncoding: ['rc4'],
        deadCodeInjection: false,
        stringArrayCallsTransform: true,
        numbersToExpressions: true,
        target: 'node',
      }
    }
  },
};