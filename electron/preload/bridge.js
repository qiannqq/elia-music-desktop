const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  minimize: () => ipcRenderer.invoke('win:minimize'),
  maximize: () => ipcRenderer.invoke('win:maximize'),
  close: () => ipcRenderer.invoke('win:close'),
  selectDirectory: () => ipcRenderer.invoke('dialog:selectDirectory'),
  saveFile: (filePath, data) => ipcRenderer.invoke('fs:saveFile', filePath, data),
});
