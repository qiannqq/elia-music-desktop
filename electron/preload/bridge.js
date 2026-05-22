const { contextBridge, ipcRenderer, webFrame } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  minimize: () => ipcRenderer.invoke('win:minimize'),
  maximize: () => ipcRenderer.invoke('win:maximize'),
  close: () => ipcRenderer.invoke('win:close'),
  selectDirectory: () => ipcRenderer.invoke('dialog:selectDirectory'),
  saveFile: (filePath, data) => ipcRenderer.invoke('fs:saveFile', filePath, data),
  fileExists: (filePath) => ipcRenderer.invoke('fs:fileExists', filePath),
  showItemInFolder: (filePath) => ipcRenderer.invoke('shell:showItemInFolder', filePath),
  setZoomFactor: (factor) => webFrame.setZoomFactor(factor),
  getZoomFactor: () => webFrame.getZoomFactor(),
});
