// Flair Web: keeps the extension's service worker running (Chrome wakes it
// for each event; Flair Web's events arrive over its bridge instead).
(function keep() {
    let port;
    try { port = chrome.runtime.connect({ name: '__flair_keep' }); }
    catch (e) { setTimeout(keep, 2000); return; }
    const timer = setInterval(() => { try { port.postMessage('ping'); } catch (e) { clearInterval(timer); } }, 20000);
    port.onDisconnect.addListener(() => { clearInterval(timer); setTimeout(keep, 500); });
})();
