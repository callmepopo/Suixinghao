/* 在 HiDeck 侧边栏注入“网页电话”入口。
   由 NPM 在 HiDeck 首页 HTML 里插入一个 <script src="/voice-test/menu.js"> 引入，
   不改 HiDeck 源码与镜像。脚本自己找侧边栏、跟着登录/登出与折叠状态同步，重复执行无副作用。 */
(function () {
  if (window.__hideckVoiceMenu) return;
  window.__hideckVoiceMenu = true;

  var HREF = '/voice-test/';
  var LABEL = '网页电话';
  var MY_CLASS = 'voice-menu-entry';

  var style = document.createElement('style');
  style.textContent =
    'a.' + MY_CLASS + '{display:flex;align-items:center;gap:10px;height:50px;margin:2px 8px;padding:0 12px;' +
    'border-radius:8px;color:var(--el-menu-text-color,#303133);text-decoration:none;font-size:14px;' +
    'line-height:1;cursor:pointer;transition:background-color .2s,color .2s;box-sizing:border-box}' +
    'a.' + MY_CLASS + ':hover{background:var(--el-menu-hover-bg-color,rgba(0,0,0,.06));color:var(--el-menu-active-color,#2864ee)}' +
    'a.' + MY_CLASS + ' svg{width:18px;height:18px;flex:none;fill:currentColor}' +
    '.sidebar-shell .el-menu--collapse a.' + MY_CLASS + '{justify-content:center;padding:0}';
  document.head.appendChild(style);

  var ICON =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.6 10.8c1.4 2.8 3.8 5.1 6.6 6.6l2.2-2.2c.3-.3.7-.4 1-.2 1.1.4 2.4.6 3.6.6.6 0 1 .4 1 1V20c0 .6-.4 1-1 1C10.6 21 3 13.4 3 4c0-.6.4-1 1-1h3.5c.6 0 1 .4 1 1 0 1.3.2 2.5.6 3.6.1.4 0 .8-.2 1l-2.3 2.2z"/></svg>';

  function make() {
    var a = document.createElement('a');
    a.className = MY_CLASS;
    a.href = HREF;
    a.title = LABEL;
    a.setAttribute('aria-label', LABEL);
    a.innerHTML = ICON + '<span>' + LABEL + '</span>';
    return a;
  }

  function sync() {
    var menu = document.querySelector('.app-sidebar .sidebar-menu');
    if (!menu) return;
    var aside = menu.closest('.app-sidebar');
    var mine = aside && aside.querySelector('a.' + MY_CLASS);
    if (menu.nextElementSibling && menu.nextElementSibling.className === MY_CLASS) return;
    if (mine) mine.remove();
    if (menu.parentNode) menu.parentNode.insertBefore(make(), menu.nextSibling);
  }

  var pending = false;
  function schedule() {
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () { pending = false; sync(); });
  }
  new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', schedule);
  sync();
})();
