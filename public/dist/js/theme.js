(function(){
  'use strict';
  const KEY='qqmusic_theme';
  const root=document.documentElement;

  function getSystemTheme(){
    return window.matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light';
  }

  function applyTheme(mode){
    const theme=mode==='system'?getSystemTheme():mode;
    root.classList.add('theme-transition');
    root.setAttribute('data-theme',theme);
    setTimeout(()=>root.classList.remove('theme-transition'),400);
  }

  function getSaved(){
    return localStorage.getItem(KEY)||'system';
  }

  function save(mode){
    localStorage.setItem(KEY,mode);
  }

  function init(){
    const saved=getSaved();
    const theme=saved==='system'?getSystemTheme():saved;
    root.setAttribute('data-theme',theme);

    const mq=window.matchMedia('(prefers-color-scheme:dark)');
    mq.addEventListener('change',()=>{
      if(getSaved()==='system') applyTheme('system');
    });

    const radios=document.querySelectorAll('input[name="theme"]');
    radios.forEach(r=>{
      r.checked=r.value===saved;
      r.addEventListener('change',()=>{
        save(r.value);
        applyTheme(r.value);
      });
    });
  }

  window.ThemeManager={init,applyTheme,getSaved,save,getSystemTheme};
})();
