// Flair Web — the content-script side of the bridge, first in every frame.
// It tells the extension's worker which tab and frame it is (Flair Web
// checks a one-time mark in the page), then carries tabs.sendMessage,
// tabs.connect and scripting into this frame's isolated world.
(() => {
'use strict';
const g = globalThis;
if (g.__flairContentLoaded) return;
g.__flairContentLoaded = true;
const chrome = g.chrome;
if (!chrome || !chrome.runtime || !chrome.runtime.id) return;
const rt = chrome.runtime;
const INTERNAL = '__flair';

if (!chrome.dom) {
    try {
        chrome.dom = { openOrClosedShadowRoot: (el) => (el && (el.openOrClosedShadowRoot ? el.openOrClosedShadowRoot() : el.shadowRoot)) || null };
    } catch (e) {}
}

// ------------------------------------------------------------------ the extension's listeners
// Qt gives content scripts no tabs.sendMessage; the messages arrive here and
// go to the listeners the extension's content scripts register.
const messageListeners = [];
const connectListeners = [];
function capture(event, list) {
    if (!event || !event.addListener) return;
    const add = event.addListener.bind(event);
    const remove = event.removeListener.bind(event);
    try {
        event.addListener = (f, ...rest) => { if (typeof f === 'function' && !list.includes(f)) list.push(f); add(f, ...rest); };
        event.removeListener = (f) => { const i = list.indexOf(f); if (i >= 0) list.splice(i, 1); remove(f); };
        event.hasListener = (f) => list.includes(f);
        event.hasListeners = () => list.length > 0;
    } catch (e) {}
}
capture(rt.onMessage, messageListeners);
capture(rt.onConnect, connectListeners);

function deliver(message, sender) {
    return new Promise((resolve) => {
        if (!messageListeners.length) { resolve({ noListener: true }); return; }
        let done = false;
        let async = false;
        const finish = (r) => { if (!done) { done = true; resolve(r); } };
        const sendResponse = (response) => finish({ hasResponse: true, response });
        for (const f of messageListeners.slice()) {
            let r;
            try { r = f(message, sender, sendResponse); } catch (e) { console.error(e); continue; }
            if (r === true) async = true;
            else if (r && typeof r.then === 'function') {
                async = true;
                r.then(v => finish({ hasResponse: v !== undefined, response: v }), () => finish({}));
            }
        }
        if (!async) finish({});
    });
}

class FakeEvent {
    constructor() { this.listeners = []; }
    addListener(f) { if (!this.listeners.includes(f)) this.listeners.push(f); }
    removeListener(f) { this.listeners = this.listeners.filter(x => x !== f); }
    hasListener(f) { return this.listeners.includes(f); }
    hasListeners() { return this.listeners.length > 0; }
    dispatch(args) { for (const f of this.listeners.slice()) try { f(...args); } catch (e) { console.error(e); } }
}

// ------------------------------------------------------------------ who we are, for the extension
// Qt doesn't tell the extension which tab and frame a content script's
// message comes from (sender.tab, sender.frameId); once Flair Web has
// identified this frame, messages and ports carry it.
let whereabouts = null;
let identified;
const ready = new Promise(r => { identified = r; });
const nativeSend = rt.sendMessage.bind(rt);
const nativeConnect = rt.connect.bind(rt);
try {
    rt.sendMessage = function (...args) {
        const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        if (args.length > 1 && typeof args[0] === 'string' && args[0] !== rt.id && /^[a-p]{32}$/.test(args[0]))
            return cb ? nativeSend(...args, cb) : nativeSend(...args);
        if (args.length > 1 && args[0] === rt.id) args.shift();
        const [message, options] = args;
        const p = ready.then(() => whereabouts
            ? nativeSend({ __flairenv: 1, tab: whereabouts.tab, frameId: whereabouts.frameId, message }, options)
            : nativeSend(message, options));
        if (!cb) return p;
        p.then(r => cb(r), () => cb());
        return undefined;
    };
    rt.connect = function (a, b) {
        const info = typeof a === 'object' && a !== null ? a : (b || {});
        if (typeof a === 'string' && a !== rt.id) return nativeConnect(a, b);
        const name = info.name || '';
        // The extension sees a port with its own name; underneath, the
        // name carries where it comes from (until we know, messages wait).
        const onMessage = new FakeEvent(), onDisconnect = new FakeEvent();
        const queue = [];
        let real = null, closed = false;
        const proxy = {
            name, sender: undefined, onMessage, onDisconnect,
            postMessage(m) {
                if (g.__flairTracing) console.log('port', name, 'out', JSON.stringify(m).slice(0, 160));
                if (closed) throw new Error('Attempting to use a disconnected port object');
                if (real) real.postMessage(m); else queue.push(m);
            },
            disconnect() { if (closed) return; closed = true; if (real) real.disconnect(); },
        };
        const open = () => {
            if (closed) return;
            real = whereabouts ? nativeConnect({ name: '__flairp:' + JSON.stringify({ t: whereabouts.tab, f: whereabouts.frameId, n: name }) })
                               : nativeConnect({ name });
            const trace = (what, extra) => { if (g.__flairTracing) console.log('port', name, what, extra === undefined ? '' : JSON.stringify(extra).slice(0, 160)); };
            trace('open');
            real.onMessage.addListener((m) => { trace('in', m); onMessage.dispatch([m, proxy]); });
            real.onDisconnect.addListener(() => { trace('closed', rt.lastError && rt.lastError.message); closed = true; onDisconnect.dispatch([proxy]); });
            while (queue.length) real.postMessage(queue.shift());
        };
        if (whereabouts) open(); else ready.then(open);
        return proxy;
    };
} catch (e) {}

// ------------------------------------------------------------------ the link to the worker
const nonce = Math.random().toString(36).slice(2) + Date.now().toString(36);
const MARK = 'data-flair-ext';
let port = null;
let alive = true;
const tabPorts = new Map();

function mark(on) {
    const el = document.documentElement;
    if (!el) return false;
    const list = (el.getAttribute(MARK) || '').split(' ').filter(x => x && x !== nonce);
    if (on) list.push(nonce);
    if (list.length) el.setAttribute(MARK, list.join(' ')); else el.removeAttribute(MARK);
    return true;
}

function hello() {
    if (!mark(true)) {
        new MutationObserver((_, observer) => { if (document.documentElement) { observer.disconnect(); hello(); } })
            .observe(document, { childList: true });
        return;
    }
    try { port.postMessage({ type: 'hello', nonce, top: g === g.top, url: location.href }); } catch (e) {}
    setTimeout(identified, 4000);
}

function connect() {
    if (!alive) return;
    try { port = nativeConnect({ name: INTERNAL + '_cs' }); }
    catch (e) { alive = false; return; } // the extension went away
    port.onMessage.addListener(onMessage);
    port.onDisconnect.addListener(() => {
        port = null;
        for (const [, p] of tabPorts) p.onDisconnect.dispatch([p]);
        tabPorts.clear();
        // The worker restarted: find it again.
        setTimeout(connect, 300 + Math.random() * 700);
    });
    hello();
}

function reply(id, payload) {
    try { port.postMessage(Object.assign({ type: 'reply', id }, payload)); } catch (e) {}
}

async function load(url) {
    const separator = url.includes('?') ? '&' : '?';
    return import(url + separator + 'n=' + Math.random().toString(36).slice(2));
}

const styles = new Map();
function insertCss(css) {
    const style = document.createElement('style');
    style.setAttribute('data-flair', '');
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
    const list = styles.get(css) || [];
    list.push(style);
    styles.set(css, list);
}
function removeCss(css) {
    const list = styles.get(css) || [];
    const style = list.pop();
    if (style) style.remove();
}


async function onMessage(msg) {
    if (!msg || typeof msg !== 'object') return;
    switch (msg.type) {
    case 'ready':
        mark(false);
        if (msg.tabId >= 0) whereabouts = { tab: msg.tab || { id: msg.tabId }, frameId: msg.frameId };
        if (msg.trace && !g.__flairTracing) {
            g.__flairTracing = true;
            for (const level of ['error', 'warn', 'log']) {
                const original = console[level].bind(console);
                console[level] = (...args) => {
                    original(...args);
                    const text = args.map(a => { try { return a instanceof Error ? a.stack || String(a) : typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); } }).join(' ');
                    try { port.postMessage({ type: 'log', text: level + ' ' + location.host + ' ' + text.slice(0, 400) }); } catch (e) {}
                };
            }
            g.addEventListener('error', (e) => console.error('uncaught', e.message, e.filename + ':' + e.lineno));
            g.addEventListener('unhandledrejection', (e) => console.error('unhandled', e.reason));
        }
        identified();
        if (msg.inject) {
            for (const css of msg.inject.css || []) {
                try { insertCss(await (await fetch(css)).text()); } catch (e) {}
            }
            for (const js of msg.inject.js || []) {
                if (js.runAt !== 'document_start' && document.readyState === 'loading')
                    await new Promise(r => document.addEventListener('DOMContentLoaded', r, { once: true }));
                try { await load(js.url); } catch (e) { console.warn('[Flair Web]', e); }
            }
        }
        break;
    case 'message': {
        const r = await deliver(msg.message, msg.sender || { id: rt.id });
        reply(msg.id, r);
        break;
    }
    case 'exec':
        try {
            const mod = await load(msg.url);
            let result = msg.files ? undefined : (typeof mod.default === 'function' ? mod.default(...(msg.args || [])) : mod.default);
            if (result && typeof result.then === 'function') result = await result;
            try { JSON.stringify(result); } catch (e) { result = undefined; }
            reply(msg.id, { result: result === undefined ? null : result });
        } catch (e) {
            reply(msg.id, { error: String(e && e.message || e) });
        }
        break;
    case 'css':
        if (msg.op === 'remove') removeCss(msg.css); else insertCss(msg.css);
        reply(msg.id, {});
        break;
    case 'connect': {
        const id = msg.portId;
        const p = {
            name: msg.name,
            sender: { id: rt.id },
            onMessage: new FakeEvent(),
            onDisconnect: new FakeEvent(),
            postMessage(message) { try { port.postMessage({ type: 'portMessage', portId: id, message }); } catch (e) {} },
            disconnect() { tabPorts.delete(id); try { port.postMessage({ type: 'portDisconnect', portId: id }); } catch (e) {} },
        };
        tabPorts.set(id, p);
        for (const f of connectListeners.slice()) try { f(p); } catch (e) { console.error(e); }
        break;
    }
    case 'portMessage': {
        const p = tabPorts.get(msg.portId);
        if (p) p.onMessage.dispatch([msg.message, p]);
        break;
    }
    case 'portDisconnect': {
        const p = tabPorts.get(msg.portId);
        if (p) { tabPorts.delete(msg.portId); p.onDisconnect.dispatch([p]); }
        break;
    }
    }
}

connect();
})();
