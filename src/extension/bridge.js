// Flair Web — the chrome.* APIs Qt WebEngine leaves out, for an extension's
// service worker and pages. Loaded before the extension's own code; talks
// to Flair Web over a local WebSocket. Content scripts get content.js.
(() => {
'use strict';
const g = globalThis;
if (g.__flairBridgeLoaded) return;
g.__flairBridgeLoaded = true;
const chrome = g.chrome;
if (!chrome || !chrome.runtime || !chrome.runtime.id) return;
const config = g.__flairBridge || { ports: [], token: '' };
const extId = chrome.runtime.id;
const isWorker = typeof ServiceWorkerGlobalScope !== 'undefined' && g instanceof ServiceWorkerGlobalScope;
const manifest = chrome.runtime.getManifest();
const log = (...a) => console.warn('[Flair Web]', ...a);

// ------------------------------------------------------------------ transport
let socket = null;
let connecting = null;
let nextId = 1;
const pending = new Map();
const outbox = [];

function connect() {
    if (socket || connecting) return;
    connecting = true;
    const ports = config.ports.slice();
    const attempt = () => {
        const port = ports.shift();
        if (port === undefined) { connecting = null; setTimeout(connect, 2000); return; }
        let ws;
        try {
            ws = new WebSocket(`ws://127.0.0.1:${port}/ws?ext=${extId}&token=${config.token}` +
                               `&kind=${isWorker ? 'worker' : 'page'}&url=${encodeURIComponent(location.href)}`);
        } catch (e) { attempt(); return; }
        let opened = false;
        ws.onopen = () => {
            opened = true; socket = ws; connecting = null;
            while (outbox.length) ws.send(outbox.shift());
        };
        ws.onmessage = (e) => receive(e.data);
        ws.onerror = () => {};
        ws.onclose = () => {
            if (!opened) { attempt(); return; }
            socket = null;
            for (const [, p] of pending) p.reject(new Error('Flair Web: connection lost'));
            pending.clear();
            setTimeout(connect, 500);
        };
    };
    attempt();
}

function call(method, args) {
    return new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        const text = JSON.stringify({ i: id, m: method, a: args === undefined ? [] : args });
        if (socket && socket.readyState === 1) socket.send(text);
        else { outbox.push(text); connect(); }
    });
}

function receive(data) {
    let msg;
    try { msg = JSON.parse(data); } catch (e) { return; }
    if (msg.ka) return;
    if (msg.i !== undefined) {
        const p = pending.get(msg.i);
        if (!p) return;
        pending.delete(msg.i);
        if (msg.e !== undefined) p.reject(new Error(msg.e)); else p.resolve(msg.r === null ? undefined : msg.r);
        return;
    }
    if (msg.ev) {
        if (msg.ev === '__trace') { startTrace(); return; }
        if (msg.ev === 'contextMenus.onClicked') menuClicked(msg.a);
        const ev = events.get(msg.ev);
        if (ev) ev.dispatch(msg.a || []);
    }
}

// Diagnostics (FLAIRWEB_EXTLOG): the context's errors and console go to Flair Web's log.
let tracing = false;
function startTrace() {
    if (tracing) return;
    tracing = true;
    const send = (kind, args) => {
        const text = args.map(a => { try { return a instanceof Error ? a.stack || String(a) : typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); } }).join(' ');
        call('flair.log', [kind, text]).catch(() => {});
    };
    for (const level of ['error', 'warn', 'log', 'info']) {
        const original = console[level].bind(console);
        console[level] = (...args) => { original(...args); send(level, args); };
    }
    g.addEventListener('error', (e) => send('uncaught', [e.message, (e.filename || '') + ':' + e.lineno]));
    g.addEventListener('unhandledrejection', (e) => send('unhandled', [e.reason]));
    send('trace', ['on', location.href]);
    const sendMessage = chrome.runtime.sendMessage.bind(chrome.runtime);
    try {
        chrome.runtime.sendMessage = (...args) => {
            send('sendMessage', [safe(args.find(a => typeof a === 'object'))]);
            const r = sendMessage(...args);
            if (r && r.then) r.then(v => send('sendMessage→', [safe(v)]), e => send('sendMessage✗', [String(e)]));
            return r;
        };
    } catch (e) {}
}
function safe(v) { try { return JSON.stringify(v).slice(0, 200); } catch (e) { return String(v); } }

// ------------------------------------------------------------------ helpers
const events = new Map();
class FlairEvent {
    constructor(name) { this.name = name; this.listeners = []; }
    addListener(f) { if (typeof f === 'function' && !this.listeners.includes(f)) this.listeners.push(f); connect(); }
    removeListener(f) { this.listeners = this.listeners.filter(x => x !== f); }
    hasListener(f) { return this.listeners.includes(f); }
    hasListeners() { return this.listeners.length > 0; }
    dispatch(args) {
        for (const f of this.listeners.slice()) {
            try { f(...args); } catch (e) { console.error(e); }
        }
    }
}
function ev(name) {
    if (!events.has(name)) events.set(name, new FlairEvent(name));
    return events.get(name);
}

function setLastError(error) {
    try {
        Object.defineProperty(chrome.runtime, 'lastError', { value: error ? { message: String(error.message || error) } : undefined,
                                                             configurable: true, writable: true });
    } catch (e) {}
}

// Wraps a promise-returning implementation so it also takes a callback.
function both(impl) {
    return function (...args) {
        const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        let p;
        try { p = Promise.resolve(impl(...args)); } catch (e) { p = Promise.reject(e); }
        if (!cb) return p;
        p.then(r => { try { cb(r); } catch (e) { console.error(e); } },
               e => { setLastError(e); try { cb(); } catch (x) { console.error(x); } finally { setLastError(null); } });
        return undefined;
    };
}
const remote = (method) => both((...args) => call(method, args));
const ok = (value) => both(() => value);

function define(name, value) {
    const current = chrome[name];
    if (current && typeof current === 'object') {
        for (const key of Object.keys(value))
            if (!(key in current)) try { current[key] = value[key]; } catch (e) {}
        return;
    }
    try { chrome[name] = value; } catch (e) {
        try { Object.defineProperty(chrome, name, { value, configurable: true, writable: true }); } catch (x) {}
    }
}
function replace(name, value) {
    try { Object.defineProperty(chrome, name, { value, configurable: true, writable: true, enumerable: true }); } catch (e) {}
    if (chrome[name] === value) return;
    // The native object stays: our methods go onto it, over Qt's.
    const target = chrome[name];
    if (!target || typeof target !== 'object') { define(name, value); return; }
    for (const key of Object.keys(value)) {
        try { Object.defineProperty(target, key, { value: value[key], configurable: true, writable: true, enumerable: true }); }
        catch (e) { try { target[key] = value[key]; } catch (x) {} }
    }
}

function extUrl(u) {
    if (!u) return u;
    return /^[a-z][a-z0-9+.-]*:/i.test(u) ? u : chrome.runtime.getURL(u);
}

async function imageToDataUrl(image) {
    // ImageData (or a {size: ImageData} dictionary) to a PNG data: URL.
    const data = image instanceof ImageData ? image : Object.values(image).pop();
    if (!(data instanceof ImageData) || typeof OffscreenCanvas === 'undefined') return '';
    const canvas = new OffscreenCanvas(data.width, data.height);
    canvas.getContext('2d').putImageData(data, 0, 0);
    const blob = await canvas.convertToBlob({ type: 'image/png' });
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return 'data:image/png;base64,' + btoa(s);
}

// ------------------------------------------------------------------ internal messaging
// Our own ports and messages stay invisible to the extension's listeners.
const INTERNAL = '__flair';
function guardEvent(event, isInternal) {
    if (!event || !event.addListener || event.__flairGuarded) return;
    const add = event.addListener.bind(event);
    const remove = event.removeListener.bind(event);
    const has = event.hasListener ? event.hasListener.bind(event) : null;
    const wrapped = new Map();
    try {
        Object.defineProperty(event, '__flairGuarded', { value: true });
        Object.defineProperty(event, '__flairAdd', { value: add });
        event.addListener = (f, ...rest) => {
            if (typeof f !== 'function' || wrapped.has(f)) return;
            const w = function (...args) {
                if (isInternal(...args)) return undefined;
                args = unwrap(event, args);
                if (tracing) call('flair.log', ['event', event === chrome.runtime.onMessage ? 'onMessage' : 'onConnect', safe(args[0])]).catch(() => {});
                return f.apply(this, args);
            };
            wrapped.set(f, w);
            add(w, ...rest);
        };
        event.removeListener = (f) => { const w = wrapped.get(f); if (w) { wrapped.delete(f); remove(w); } };
        event.hasListener = (f) => wrapped.has(f) || (has ? has(f) : false);
        event.hasListeners = () => wrapped.size > 0;
    } catch (e) {}
}
guardEvent(chrome.runtime.onConnect, (port) => port && typeof port.name === 'string' && port.name.startsWith(INTERNAL) && !port.name.startsWith('__flairp:'));
guardEvent(chrome.runtime.onMessage, (msg) => msg && typeof msg === 'object' && msg[INTERNAL] !== undefined);

// What content.js adds (its tab and frame) becomes the sender's.
function unwrap(event, args) {
    if (event === chrome.runtime.onMessage) {
        const msg = args[0];
        if (msg && typeof msg === 'object' && msg.__flairenv === 1) {
            const sender = Object.assign({}, args[1] || {}, { tab: msg.tab, frameId: msg.frameId,
                                                              documentId: msg.tab ? msg.tab.id + ':' + msg.frameId : undefined });
            return [msg.message, sender, args[2]];
        }
    } else if (event === chrome.runtime.onConnect) {
        const port = args[0];
        if (port && typeof port.name === 'string' && port.name.startsWith('__flairp:')) {
            let info = {};
            try { info = JSON.parse(port.name.slice(9)); } catch (e) {}
            const sender = Object.assign({}, port.sender || {}, { tab: info.t, frameId: info.f,
                                                                  documentId: info.t ? info.t.id + ':' + info.f : undefined });
            const proxy = {
                name: info.n || '', sender,
                postMessage: (m) => port.postMessage(m),
                disconnect: () => port.disconnect(),
                onMessage: { addListener: (f) => port.onMessage.addListener((m) => f(m, proxy)), removeListener: () => {},
                             hasListener: () => false, hasListeners: () => true },
                onDisconnect: { addListener: (f) => port.onDisconnect.addListener(() => f(proxy)), removeListener: () => {},
                                hasListener: () => false, hasListeners: () => true },
            };
            return [proxy];
        }
    }
    return args;
}

// ------------------------------------------------------------------ content frames (worker side)
// Every frame's content.js connects here; Flair Web tells which tab and
// frame it is. tabs.sendMessage and scripting go through these ports.
const frames = new Map();   // key -> {port, tabId, frameId, url, documentId}
let frameSeq = 1;
let messageSeq = 1;
const waiting = new Map();  // message id -> {resolve, reject, left, timer}

function framesOf(tabId, frameIds, allFrames) {
    const list = [...frames.values()].filter(f => f.tabId === tabId);
    if (allFrames) return list;
    const ids = frameIds && frameIds.length ? frameIds : [0];
    return list.filter(f => ids.includes(f.frameId));
}

async function waitForFrames(tabId, frameIds, allFrames) {
    for (let i = 0; i < 20; i++) {
        const list = framesOf(tabId, frameIds, allFrames);
        if (list.length) return list;
        await new Promise(r => setTimeout(r, 100));
    }
    return [];
}

function ask(frame, payload) {
    return new Promise((resolve, reject) => {
        const id = messageSeq++;
        const timer = setTimeout(() => { waiting.delete(id); resolve({ timeout: true }); }, 30000);
        waiting.set(id, { resolve, reject, timer });
        try { frame.port.postMessage(Object.assign({ id }, payload)); }
        catch (e) { clearTimeout(timer); waiting.delete(id); resolve({ gone: true }); }
    });
}

function onFramePort(port) {
    const key = frameSeq++;
    port.onMessage.addListener(async (msg) => {
        if (!msg || typeof msg !== 'object') return;
        if (msg.type === 'hello') {
            let where = null;
            for (let i = 0; i < 4 && !where; i++) {
                try { where = await call('tabs._identify', [{ nonce: msg.nonce, url: msg.url, top: msg.top }]); } catch (e) {}
                if (!where) await new Promise(r => setTimeout(r, 250 * (i + 1)));
            }
            if (!where) { try { port.postMessage({ type: 'ready', tabId: -1 }); } catch (e) {} return; }
            frames.set(key, { port, tabId: where.tabId, frameId: where.frameId, url: msg.url });
            let inject = null;
            try { inject = await call('scripting._matching', [{ url: msg.url, frameId: where.frameId }]); } catch (e) {}
            try { port.postMessage({ type: 'ready', tabId: where.tabId, frameId: where.frameId, tab: where.tab, inject, trace: tracing }); } catch (e) {}
            return;
        }
        if (msg.type === 'log') { call('flair.log', ['content', msg.text]).catch(() => {}); return; }
        if (msg.type === 'reply') {
            const w = waiting.get(msg.id);
            if (!w) return;
            waiting.delete(msg.id);
            clearTimeout(w.timer);
            w.resolve(msg);
            return;
        }
        if (msg.type === 'portMessage' || msg.type === 'portDisconnect') {
            const p = tabPorts.get(msg.portId);
            if (!p) return;
            if (msg.type === 'portMessage') p.onMessage.dispatch([msg.message, p]);
            else { tabPorts.delete(msg.portId); p.onDisconnect.dispatch([p]); }
        }
    });
    port.onDisconnect.addListener(() => {
        frames.delete(key);
        for (const [id, p] of tabPorts) if (p.__frameKey === key) { tabPorts.delete(id); p.onDisconnect.dispatch([p]); }
    });
}

// Pages relay frame work to the worker, which holds the ports.
const relayOps = {
    async sendMessage(tabId, message, options) {
        options = options || {};
        const list = await waitForFrames(tabId, options.frameId !== undefined ? [options.frameId] : null, options.frameId === undefined);
        if (!list.length) throw new Error('Could not establish connection. Receiving end does not exist.');
        const answers = await Promise.all(list.map(f => ask(f, { type: 'message', message, sender: { id: extId } })));
        const hit = answers.find(a => a && a.hasResponse);
        if (hit) return hit.response;
        if (answers.every(a => a && a.noListener)) throw new Error('Could not establish connection. Receiving end does not exist.');
        return undefined;
    },
    async executeScript(injection) {
        const target = injection.target || {};
        const list = await waitForFrames(target.tabId, target.frameIds, target.allFrames);
        if (!list.length) throw new Error('Cannot access contents of the page. Extension manifest must request permission to access the respective host.');
        let payload;
        if (injection.func) {
            const url = await call('flair.code', [injection.func]);
            payload = { type: 'exec', url, args: injection.args || [] };
        } else {
            const base = await call('flair.fileBase', []);
            const files = (injection.files || []).map(f => f.replace(/^\/+/, ''));
            payload = { type: 'exec', url: base + '?files=' + encodeURIComponent(files.join(',')), args: [], files: true };
        }
        const answers = await Promise.all(list.map(f => ask(f, payload).then(a => ({ frame: f, a }))));
        return answers.filter(x => x.a && !x.a.gone).map(({ frame, a }) => {
            if (a.error) throw new Error(a.error);
            return { frameId: frame.frameId, documentId: String(frame.tabId) + ':' + frame.frameId, result: a.result };
        });
    },
    async css(op, injection) {
        const target = injection.target || {};
        const list = await waitForFrames(target.tabId, target.frameIds, target.allFrames);
        let css = injection.css || '';
        if (injection.files && injection.files.length) {
            const texts = await Promise.all(injection.files.map(f => fetch(chrome.runtime.getURL(f)).then(r => r.text()).catch(() => '')));
            css = texts.join('\n');
        }
        await Promise.all(list.map(f => ask(f, { type: 'css', op, css })));
    },
    connect(portId, tabId, info) {
        const list = framesOf(tabId, info.frameId !== undefined ? [info.frameId] : null, info.frameId === undefined);
        for (const f of list) {
            try { f.port.postMessage({ type: 'connect', portId, name: info.name || '' }); } catch (e) {}
        }
        return list;
    },
};

let relay = null;
const relayWaiting = new Map();
function relayCall(op, ...args) {
    if (isWorker) return relayOps[op](...args);
    return new Promise((resolve, reject) => {
        if (!relay) {
            relay = chrome.runtime.connect({ name: INTERNAL + '_relay' });
            relay.onMessage.addListener((m) => {
                const w = relayWaiting.get(m.id);
                if (!w) return;
                relayWaiting.delete(m.id);
                if (m.error) w.reject(new Error(m.error)); else w.resolve(m.result);
            });
            relay.onDisconnect.addListener(() => {
                relay = null;
                for (const [, w] of relayWaiting) w.reject(new Error('Flair Web: worker unavailable'));
                relayWaiting.clear();
            });
        }
        const id = messageSeq++;
        relayWaiting.set(id, { resolve, reject });
        relay.postMessage({ id, op, args });
    });
}

if (isWorker) {
    // Our listener goes straight to the native event (unguarded).
    const nativeAdd = chrome.runtime.onConnect.__flairAdd || chrome.runtime.onConnect.addListener;
    const listener = (port) => {
        if (port.name === INTERNAL + '_cs') onFramePort(port);
        else if (port.name === INTERNAL + '_keep') port.onMessage.addListener(() => {});
        else if (port.name === INTERNAL + '_relay') {
            port.onMessage.addListener(async (m) => {
                try { port.postMessage({ id: m.id, result: await relayOps[m.op](...m.args) }); }
                catch (e) { port.postMessage({ id: m.id, error: String(e && e.message || e) }); }
            });
        }
    };
    nativeAdd.call(chrome.runtime.onConnect, listener);
    // Stay reachable while Flair Web runs.
    connect();
}

// ------------------------------------------------------------------ tabs
const TAB_ID_NONE = -1;
const tabPorts = new Map();
let portSeq = 1;
function makeTabPort(tabId, info) {
    const portId = 'p' + (portSeq++);
    const port = {
        name: (info && info.name) || '',
        sender: undefined,
        onMessage: new FlairEvent('port.onMessage'),
        onDisconnect: new FlairEvent('port.onDisconnect'),
        postMessage(message) {
            for (const f of framesOf(tabId, null, true))
                try { f.port.postMessage({ type: 'portMessage', portId, message }); } catch (e) {}
        },
        disconnect() {
            tabPorts.delete(portId);
            for (const f of framesOf(tabId, null, true))
                try { f.port.postMessage({ type: 'portDisconnect', portId }); } catch (e) {}
        },
    };
    tabPorts.set(portId, port);
    if (isWorker) relayOps.connect(portId, tabId, info || {});
    return port;
}

const tabs = {
    TAB_ID_NONE,
    TAB_INDEX_NONE: -1,
    MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2,
    query: remote('tabs.query'),
    get: remote('tabs.get'),
    getCurrent: both(() => isWorker ? undefined : call('tabs.getCurrent', [])),
    create: both((props) => call('tabs.create', [Object.assign({}, props, { url: extUrl(props && props.url) })])),
    update: both((a, b) => {
        const [id, props] = typeof a === 'number' ? [a, b] : [undefined, a];
        return call('tabs.update', [id, Object.assign({}, props, props && props.url ? { url: extUrl(props.url) } : {})]);
    }),
    remove: remote('tabs.remove'),
    reload: both((a, b) => call('tabs.reload', typeof a === 'number' ? [a, b || {}] : [undefined, a || {}])),
    duplicate: remote('tabs.duplicate'),
    goBack: remote('tabs.goBack'),
    goForward: remote('tabs.goForward'),
    discard: remote('tabs.discard'),
    highlight: remote('tabs.highlight'),
    move: remote('tabs.move'),
    getZoom: remote('tabs.getZoom'),
    setZoom: both((a, b) => call('tabs.setZoom', typeof a === 'number' && b !== undefined ? [a, b] : [undefined, a])),
    getZoomSettings: ok({ mode: 'automatic', scope: 'per-origin', defaultZoomFactor: 1 }),
    setZoomSettings: ok(undefined),
    captureVisibleTab: both((a, b) => call('tabs.captureVisibleTab', [typeof a === 'number' ? a : null, (typeof a === 'object' ? a : b) || {}])),
    detectLanguage: ok('und'),
    group: ok(-1),
    ungroup: ok(undefined),
    sendMessage: both((tabId, message, options) => relayCall('sendMessage', tabId, message, options || {})),
    connect: (tabId, info) => makeTabPort(tabId, info),
    executeScript: both((tabId, details) => {
        details = typeof tabId === 'object' ? tabId : details;
        const id = typeof tabId === 'number' ? tabId : undefined;
        return call('tabs.get', [id]).then(t => relayCall('executeScript', { target: { tabId: t.id, allFrames: !!details.allFrames },
                                                                              files: details.file ? [details.file] : undefined })).then(r => r.map(x => x.result));
    }),
    insertCSS: both((tabId, details) => {
        details = typeof tabId === 'object' ? tabId : details;
        const id = typeof tabId === 'number' ? tabId : undefined;
        return call('tabs.get', [id]).then(t => relayCall('css', 'insert', { target: { tabId: t.id }, css: details.code,
                                                                            files: details.file ? [details.file] : undefined }));
    }),
};
for (const name of ['onCreated', 'onUpdated', 'onActivated', 'onRemoved', 'onReplaced', 'onMoved', 'onHighlighted',
                    'onAttached', 'onDetached', 'onZoomChange', 'onActiveChanged', 'onSelectionChanged'])
    tabs[name] = ev('tabs.' + name);
replace('tabs', tabs);


// ------------------------------------------------------------------ windows
const windows = {
    WINDOW_ID_NONE: -1,
    WINDOW_ID_CURRENT: -2,
    get: remote('windows.get'),
    getCurrent: remote('windows.getCurrent'),
    getLastFocused: remote('windows.getLastFocused'),
    getAll: remote('windows.getAll'),
    create: both((data) => {
        data = Object.assign({}, data || {});
        if (data.url) data.url = Array.isArray(data.url) ? data.url.map(extUrl) : extUrl(data.url);
        return call('windows.create', [data]);
    }),
    update: remote('windows.update'),
    remove: remote('windows.remove'),
};
for (const name of ['onCreated', 'onRemoved', 'onFocusChanged', 'onBoundsChanged']) windows[name] = ev('windows.' + name);
define('windows', windows);

// ------------------------------------------------------------------ action
const action = {
    setBadgeText: remote('action.setBadgeText'),
    getBadgeText: remote('action.getBadgeText'),
    setBadgeBackgroundColor: remote('action.setBadgeBackgroundColor'),
    getBadgeBackgroundColor: remote('action.getBadgeBackgroundColor'),
    setBadgeTextColor: remote('action.setBadgeTextColor'),
    getBadgeTextColor: remote('action.getBadgeTextColor'),
    setTitle: remote('action.setTitle'),
    getTitle: remote('action.getTitle'),
    setPopup: both((d) => call('action.setPopup', [Object.assign({}, d, { popup: d && d.popup ? extUrl(d.popup) : '' })])),
    getPopup: remote('action.getPopup'),
    setIcon: both(async (d) => {
        d = Object.assign({}, d || {});
        if (d.imageData) { d.dataUrl = await imageToDataUrl(d.imageData); delete d.imageData; }
        if (d.path && typeof d.path === 'object') {
            const sizes = Object.keys(d.path).map(Number).sort((a, b) => a - b);
            d.path = d.path[sizes.find(s => s >= 32) || sizes[sizes.length - 1]];
        }
        if (d.path) d.path = extUrl(d.path);
        return call('action.setIcon', [d]);
    }),
    enable: remote('action.enable'),
    disable: remote('action.disable'),
    isEnabled: remote('action.isEnabled'),
    openPopup: remote('action.openPopup'),
    getUserSettings: ok({ isOnToolbar: true }),
    onClicked: ev('action.onClicked'),
    onUserSettingsChanged: ev('action.onUserSettingsChanged'),
};
define('action', action);
if (!chrome.browserAction) define('browserAction', action);

// ------------------------------------------------------------------ context menus
const menuHandlers = new Map();
let menuSeq = 1;
function menuClicked(args) {
    const info = args && args[0];
    const f = info && menuHandlers.get(info.menuItemId);
    if (f) try { f(info, args[1]); } catch (e) { console.error(e); }
}
const contextMenus = {
    ACTION_MENU_TOP_LEVEL_LIMIT: 6,
    ContextType: { ALL: 'all', PAGE: 'page', FRAME: 'frame', SELECTION: 'selection', LINK: 'link', EDITABLE: 'editable',
                   IMAGE: 'image', VIDEO: 'video', AUDIO: 'audio', LAUNCHER: 'launcher', BROWSER_ACTION: 'browser_action',
                   PAGE_ACTION: 'page_action', ACTION: 'action' },
    ItemType: { NORMAL: 'normal', CHECKBOX: 'checkbox', RADIO: 'radio', SEPARATOR: 'separator' },
    create(props, cb) {
        props = Object.assign({}, props || {});
        const id = props.id !== undefined ? props.id : 'flair-menu-' + (menuSeq++);
        if (typeof props.onclick === 'function') menuHandlers.set(id, props.onclick);
        delete props.onclick;
        props.id = id;
        call('contextMenus.create', [props]).then(() => cb && cb(), (e) => { setLastError(e); try { cb && cb(); } finally { setLastError(null); } });
        return id;
    },
    update: both((id, props) => {
        props = Object.assign({}, props || {});
        if (typeof props.onclick === 'function') menuHandlers.set(id, props.onclick);
        delete props.onclick;
        return call('contextMenus.update', [id, props]);
    }),
    remove: both((id) => { menuHandlers.delete(id); return call('contextMenus.remove', [id]); }),
    removeAll: both(() => { menuHandlers.clear(); return call('contextMenus.removeAll', []); }),
    onClicked: ev('contextMenus.onClicked'),
};
define('contextMenus', contextMenus);
if (!chrome.menus) define('menus', contextMenus);

// ------------------------------------------------------------------ scripting
const scripting = {
    ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT' },
    StyleOrigin: { AUTHOR: 'AUTHOR', USER: 'USER' },
    executeScript: both(async (injection) => {
        injection = Object.assign({}, injection);
        if (typeof injection.func === 'function') injection.func = injection.func.toString();
        else if (typeof injection.function === 'function') injection.func = injection.function.toString();
        if (injection.world === 'MAIN') return call('scripting.executeMain', [injection]);
        return relayCall('executeScript', injection);
    }),
    insertCSS: both((injection) => relayCall('css', 'insert', injection)),
    removeCSS: both((injection) => relayCall('css', 'remove', injection)),
    registerContentScripts: remote('scripting.registerContentScripts'),
    getRegisteredContentScripts: remote('scripting.getRegisteredContentScripts'),
    unregisterContentScripts: remote('scripting.unregisterContentScripts'),
    updateContentScripts: remote('scripting.updateContentScripts'),
};
define('scripting', scripting);

// ------------------------------------------------------------------ webNavigation
const webNavigation = {
    getFrame: remote('webNavigation.getFrame'),
    getAllFrames: remote('webNavigation.getAllFrames'),
};
for (const name of ['onBeforeNavigate', 'onCommitted', 'onDOMContentLoaded', 'onCompleted', 'onErrorOccurred',
                    'onCreatedNavigationTarget', 'onReferenceFragmentUpdated', 'onTabReplaced', 'onHistoryStateUpdated'])
    webNavigation[name] = ev('webNavigation.' + name);
define('webNavigation', webNavigation);

// ------------------------------------------------------------------ permissions
const declared = new Set([...(manifest.permissions || []), ...(manifest.optional_permissions || [])]);
const hosts = [...(manifest.host_permissions || []), ...(manifest.optional_host_permissions || [])];
const permissions = {
    contains: both(() => true),
    getAll: both(() => ({ permissions: [...declared], origins: hosts.length ? hosts : ['<all_urls>'] })),
    request: both(() => true),
    remove: both(() => false),
    addHostAccessRequest: ok(undefined),
    removeHostAccessRequest: ok(undefined),
    onAdded: ev('permissions.onAdded'),
    onRemoved: ev('permissions.onRemoved'),
};
define('permissions', permissions);

// ------------------------------------------------------------------ privacy (settings the browser owns)
function setting(value) {
    let current = value;
    const changed = new FlairEvent('setting.onChange');
    return {
        get: both(() => ({ value: current, levelOfControl: 'controllable_by_this_extension' })),
        set: both((d) => { current = d && 'value' in d ? d.value : current; changed.dispatch([{ value: current, levelOfControl: 'controlled_by_this_extension' }]); }),
        clear: both(() => { current = value; }),
        onChange: changed,
    };
}
define('privacy', {
    services: { passwordSavingEnabled: setting(false), autofillEnabled: setting(false), autofillAddressEnabled: setting(false),
                autofillCreditCardEnabled: setting(false), alternateErrorPagesEnabled: setting(false),
                safeBrowsingEnabled: setting(false), searchSuggestEnabled: setting(true), spellingServiceEnabled: setting(false),
                translationServiceEnabled: setting(false) },
    network: { networkPredictionEnabled: setting(true), webRTCIPHandlingPolicy: setting('default') },
    websites: { thirdPartyCookiesAllowed: setting(false), hyperlinkAuditingEnabled: setting(false), referrersEnabled: setting(true),
                doNotTrackEnabled: setting(true), protectedContentEnabled: setting(true), topicsEnabled: setting(false),
                fledgeEnabled: setting(false), adMeasurementEnabled: setting(false) },
    IPHandlingPolicy: { DEFAULT: 'default', DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: 'default_public_and_private_interfaces',
                        DEFAULT_PUBLIC_INTERFACE_ONLY: 'default_public_interface_only', DISABLE_NON_PROXIED_UDP: 'disable_non_proxied_udp' },
});

// ------------------------------------------------------------------ the rest
define('extension', {
    getURL: (p) => chrome.runtime.getURL(p),
    getViews: () => (isWorker ? [] : [g]),
    getBackgroundPage: () => null,
    isAllowedIncognitoAccess: ok(false),
    isAllowedFileSchemeAccess: ok(false),
    inIncognitoContext: false,
    setUpdateUrlData: () => {},
});
if (!chrome.runtime.getBackgroundPage) try { chrome.runtime.getBackgroundPage = both(() => null); } catch (e) {}
// No native messaging hosts (desktop apps) in Flair Web: answer like Chrome
// does when the host isn't installed.
const NO_HOST = 'Specified native messaging host not found.';
if (!chrome.runtime.connectNative) try {
    chrome.runtime.connectNative = (name) => {
        const onDisconnect = new FlairEvent('native.onDisconnect');
        const port = { name, onMessage: new FlairEvent('native.onMessage'), onDisconnect,
                       postMessage() {}, disconnect() {} };
        setTimeout(() => { setLastError(new Error(NO_HOST)); try { onDisconnect.dispatch([port]); } finally { setLastError(null); } }, 0);
        return port;
    };
    chrome.runtime.sendNativeMessage = both(() => { throw new Error(NO_HOST); });
} catch (e) {}

const dnrMethods = ['getEnabledRulesets', 'updateEnabledRulesets', 'getAvailableStaticRuleCount', 'getDynamicRules',
                    'updateDynamicRules', 'getSessionRules', 'updateSessionRules', 'updateStaticRules', 'getDisabledRuleIds',
                    'isRegexSupported', 'setExtensionActionOptions', 'getMatchedRules', 'testMatchOutcome'];
const dnr = {
    MAX_NUMBER_OF_RULES: 330000, GUARANTEED_MINIMUM_STATIC_RULES: 30000, MAX_NUMBER_OF_DYNAMIC_RULES: 30000,
    MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000,
    MAX_NUMBER_OF_SESSION_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000, MAX_NUMBER_OF_REGEX_RULES: 1000,
    MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
    DYNAMIC_RULESET_ID: '_dynamic', SESSION_RULESET_ID: '_session',
    GETMATCHEDRULES_QUOTA_INTERVAL: 10, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20,
    ResourceType: { MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image',
                    FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report',
                    MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other' },
    RuleActionType: { BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme',
                      MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests' },
    DomainType: { FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty' },
    HeaderOperation: { APPEND: 'append', SET: 'set', REMOVE: 'remove' },
    RequestMethod: { CONNECT: 'connect', DELETE: 'delete', GET: 'get', HEAD: 'head', OPTIONS: 'options', PATCH: 'patch',
                     POST: 'post', PUT: 'put', OTHER: 'other' },
    UnsupportedRegexReason: { SYNTAX_ERROR: 'syntaxError', MEMORY_LIMIT_EXCEEDED: 'memoryLimitExceeded' },
    onRuleMatchedDebug: ev('declarativeNetRequest.onRuleMatchedDebug'),
};
for (const m of dnrMethods) dnr[m] = remote('declarativeNetRequest.' + m);
if (declared.has('declarativeNetRequest') || declared.has('declarativeNetRequestWithHostAccess') ||
    declared.has('declarativeNetRequestFeedback') || manifest.declarative_net_request)
    replace('declarativeNetRequest', dnr); // Qt's own sees no rulesets: Flair Web applies them

define('notifications', {
    TemplateType: { BASIC: 'basic', IMAGE: 'image', LIST: 'list', PROGRESS: 'progress' },
    PermissionLevel: { GRANTED: 'granted', DENIED: 'denied' },
    create: both((a, b) => {
        const [id, options] = typeof a === 'string' ? [a, b] : ['flair-' + Date.now(), a];
        const o = Object.assign({}, options);
        if (o.iconUrl) o.iconUrl = extUrl(o.iconUrl);
        return call('notifications.create', [id, o]).then(() => id);
    }),
    update: ok(true),
    clear: remote('notifications.clear'),
    getAll: ok({}),
    getPermissionLevel: ok('granted'),
    onClicked: ev('notifications.onClicked'),
    onClosed: ev('notifications.onClosed'),
    onButtonClicked: ev('notifications.onButtonClicked'),
    onPermissionLevelChanged: ev('notifications.onPermissionLevelChanged'),
});

define('commands', { getAll: ok([]), onCommand: ev('commands.onCommand') });
define('cookies', {
    get: remote('cookies.get'), getAll: remote('cookies.getAll'), set: remote('cookies.set'), remove: remote('cookies.remove'),
    getAllCookieStores: ok([{ id: '0', tabIds: [] }]), onChanged: ev('cookies.onChanged'),
});
define('sidePanel', { setOptions: ok(undefined), getOptions: ok({ enabled: false }), setPanelBehavior: ok(undefined),
                      getPanelBehavior: ok({ openPanelOnActionClick: false }), open: ok(undefined) });
define('downloads', { download: remote('downloads.download'), search: ok([]), onChanged: ev('downloads.onChanged'),
                      onCreated: ev('downloads.onCreated') });
define('identity', {
    getRedirectURL: (path) => `https://${extId}.chromiumapp.org/${(path || '').replace(/^\/+/, '')}`,
    launchWebAuthFlow: both((details) => call('identity.launchWebAuthFlow', [details])),
    getAuthToken: both(() => { throw new Error('OAuth2 not granted or revoked.'); }),
    getProfileUserInfo: ok({ email: '', id: '' }),
    removeCachedAuthToken: ok(undefined),
    clearAllCachedAuthTokens: ok(undefined),
    onSignInChanged: ev('identity.onSignInChanged'),
});
define('fontSettings', { getFontList: ok([]) });
define('tabGroups', { TAB_GROUP_ID_NONE: -1, query: ok([]), get: ok(undefined), update: ok(undefined), move: ok(undefined),
                      onCreated: ev('tabGroups.onCreated'), onUpdated: ev('tabGroups.onUpdated'),
                      onRemoved: ev('tabGroups.onRemoved'), onMoved: ev('tabGroups.onMoved') });

// storage.session, shared by the worker and pages.
if (chrome.storage && !chrome.storage.session) {
    const changed = ev('storage.session.onChanged');
    const area = {
        QUOTA_BYTES: 10485760,
        get: both((keys) => call('storage.session.get', [keys === undefined ? null : keys])),
        set: remote('storage.session.set'),
        remove: both((keys) => call('storage.session.remove', [Array.isArray(keys) ? keys : [keys]])),
        clear: remote('storage.session.clear'),
        getBytesInUse: ok(0),
        setAccessLevel: ok(undefined),
        onChanged: changed,
    };
    try { chrome.storage.session = area; } catch (e) {}
}

// storage.sync: Qt has none (no Google account to sync with); Flair Web
// keeps it on disk. storage.managed: no policy, so nothing.
if (chrome.storage) {
    const syncChanged = ev('storage.sync.onChanged');
    const sync = {
        QUOTA_BYTES: 102400, QUOTA_BYTES_PER_ITEM: 8192, MAX_ITEMS: 512,
        MAX_WRITE_OPERATIONS_PER_HOUR: 1800, MAX_WRITE_OPERATIONS_PER_MINUTE: 120,
        get: both((keys) => call('storage.sync.get', [keys === undefined ? null : keys])),
        set: remote('storage.sync.set'),
        remove: both((keys) => call('storage.sync.remove', [Array.isArray(keys) ? keys : [keys]])),
        clear: remote('storage.sync.clear'),
        getBytesInUse: ok(0),
        getKeys: both(() => call('storage.sync.get', [null]).then(o => Object.keys(o || {}))),
        onChanged: syncChanged,
    };
    try { Object.defineProperty(chrome.storage, 'sync', { value: sync, configurable: true, writable: true, enumerable: true }); }
    catch (e) { try { chrome.storage.sync = sync; } catch (x) {} }
    const managed = { get: ok({}), getBytesInUse: ok(0), onChanged: ev('storage.managed.onChanged') };
    try { Object.defineProperty(chrome.storage, 'managed', { value: managed, configurable: true, writable: true, enumerable: true }); }
    catch (e) {}
    // chrome.storage.onChanged also hears about sync.
    const changed = chrome.storage.onChanged;
    if (changed && changed.addListener) {
        const add = changed.addListener.bind(changed);
        const remove = changed.removeListener.bind(changed);
        const ours = new Map();
        try {
            changed.addListener = (f) => {
                add(f);
                if (!ours.has(f)) { const w = (c) => f(c, 'sync'); ours.set(f, w); syncChanged.addListener(w); }
            };
            changed.removeListener = (f) => { remove(f); const w = ours.get(f); if (w) { ours.delete(f); syncChanged.removeListener(w); } };
        } catch (e) {}
    }
}

if (!isWorker) connect();
})();
