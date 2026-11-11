const report = (...a) => console.log('SELFTEST', ...a);
chrome.contextMenus.removeAll(() => chrome.contextMenus.create({ id: 'hello', title: 'Flair test: %s', contexts: ['page', 'selection'] }));
chrome.contextMenus.onClicked.addListener((info, tab) => report('menu', info.menuItemId, tab && tab.id));
chrome.webNavigation.onCompleted.addListener((d) => { if (d.frameId === 0) report('webNavigation.onCompleted', d.url); });
chrome.tabs.onUpdated.addListener(async (tabId, change, tab) => {
  if (change.status !== 'complete' || !tab.url.startsWith('https://example.com')) return;
  try {
    const r = await chrome.scripting.executeScript({ target: { tabId }, func: (a) => document.title + '|' + a, args: ['ok'] });
    report('executeScript', JSON.stringify(r));
    report('sendMessage', JSON.stringify(await chrome.tabs.sendMessage(tabId, { ping: 1 })));
    await chrome.scripting.insertCSS({ target: { tabId }, css: 'h1 { color: red !important; }' });
    report('insertCSS', 'done');
    const main = await chrome.scripting.executeScript({ target: { tabId }, world: 'MAIN', func: () => typeof window.chrome + '/' + location.host });
    report('main', JSON.stringify(main));
    const frames = await chrome.webNavigation.getAllFrames({ tabId });
    report('frames', frames.length);
    await chrome.action.setBadgeText({ text: 'OK', tabId });
    await chrome.storage.session.set({ k: 1 });
    report('session', JSON.stringify(await chrome.storage.session.get('k')));
    report('i18n', chrome.i18n.getUILanguage());
  } catch (e) { report('FAIL', e.message); }
});
