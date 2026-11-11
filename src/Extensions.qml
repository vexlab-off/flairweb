import QtQuick
import QtQuick.Window
import QtWebEngine

// The browser's side of the extension bridge: answers the chrome.* calls
// the bridge forwards (tabs, windows, action, contextMenus, scripting,
// webNavigation…) from the real tabs and windows, and tells extensions
// what happens (tabs.onUpdated, webNavigation.onCompleted…). Private tabs
// are never shown to extensions.
QtObject {
    id: hub
    property var app: null
    property int lastTabId: 0
    property int lastWindowId: 0
    // Bumped when an extension's toolbar button or menu items change.
    property int revision: 0
    property var menus: ({})          // ext -> [item]
    property var actions: ({})        // ext -> {title, popup, badge, color, textColor, icon, enabled, tabs: {tabId: {...}}}
    property var registered: ({})     // ext -> [content script]
    property var session: ({})        // ext -> storage.session
    property var syncStore: ({})      // ext -> storage.sync (kept on disk)
    readonly property string syncFile: browser.dataPath("extension-sync.json")
    function saveSync() { browser.writeText(syncFile, JSON.stringify(syncStore)) }
    property var frameIds: ({})       // tabId -> {path: frameId}
    property int lastFrameId: 0
    property var popups: []           // ExtensionWindow objects

    property Component windowComponent: Component { ExtensionWindow {} }

    function nextTabId() { return ++lastTabId }
    function nextWindowId() { return ++lastWindowId }
    function bump() { revision++ }

    readonly property string stateFile: browser.dataPath("extension-scripts.json")
    Component.onCompleted: {
        try { registered = JSON.parse(browser.readText(stateFile) || "{}") } catch (e) { registered = {} }
        try { syncStore = JSON.parse(browser.readText(syncFile) || "{}") } catch (e) { syncStore = {} }
        for (const ext in registered) applyMainScripts(ext)
    }

    property Connections link: Connections {
        target: extensionHost
        function onCall(callId, ext, method, args, context) { hub.handle(callId, ext, method, args, context) }
    }

    function handle(callId, ext, method, args, context) {
        const fn = handlers[method]
        if (!fn) { extensionHost.reply(callId, null, "Flair Web ne prend pas encore en charge " + method + "."); return }
        let result
        try { result = fn(ext, args || [], context || {}) }
        catch (e) { extensionHost.reply(callId, null, String(e && e.message || e)); return }
        if (result && typeof result.then === "function")
            result.then(v => extensionHost.reply(callId, v === undefined ? null : v, ""),
                        e => extensionHost.reply(callId, null, String(e && e.message || e)))
        else
            extensionHost.reply(callId, result === undefined ? null : result, "")
    }
    function send(ext, name, args) { extensionHost.emitEvent(ext || "", name, args) }

    // ------------------------------------------------------------ lookups
    function windowsList() { return app ? app.windows : [] }
    function allTabs() {
        const out = []
        for (const w of windowsList()) for (const t of w.tabs) if (!t.isPrivate) out.push(t)
        return out
    }
    function tabById(id) {
        if (id === undefined || id === null) { const w = app.lastActive; return w && w.currentTab && !w.currentTab.isPrivate ? w.currentTab : null }
        return allTabs().find(t => t.tabId === id) || null
    }
    function needTab(id) {
        const t = tabById(id)
        if (!t) throw new Error("No tab with id: " + id + ".")
        return t
    }
    function windowById(id) {
        if (id === undefined || id === null || id === -2) return app.lastActive
        return windowsList().find(w => w.windowId === id) || null
    }
    function popupById(id) { return popups.find(p => p.windowId === id || p.tabId === id) || null }
    function extensionInfo(ext) { return browser.extensions.find(e => e.id === ext) || null }
    function extUrl(ext, u) { return /^[a-z][a-z0-9+.-]*:/i.test(u || "") ? u : "chrome-extension://" + ext + "/" + String(u || "").replace(/^\/+/, "") }

    function tabInfo(t) {
        if (!t) return null
        const w = t.browserWindow
        const url = t.isNewTab ? "chrome://newtab/" : t.url
        return {
            id: t.tabId, index: w.tabs.indexOf(t), windowId: w.windowId, openerTabId: t.opener ? t.opener.tabId : undefined,
            active: w.currentTab === t, highlighted: w.currentTab === t, selected: w.currentTab === t, pinned: t.pinned,
            incognito: false, url: url, pendingUrl: t.loading ? url : undefined, title: t.title,
            favIconUrl: t.icon ? t.icon.replace(/^image:\/\/favicon\//, "") : undefined,
            status: t.loading ? "loading" : "complete", audible: t.audible, mutedInfo: { muted: t.muted },
            discarded: t.sleeping, autoDiscardable: true, frozen: false, groupId: -1,
            width: Math.round(t.width), height: Math.round(t.height), lastAccessed: t.lastActive
        }
    }
    function popupTabInfo(p) {
        return { id: p.tabId, index: 0, windowId: p.windowId, active: true, highlighted: true, selected: true, pinned: false,
                 incognito: false, url: p.currentUrl, title: p.title, status: p.loading ? "loading" : "complete",
                 audible: false, mutedInfo: { muted: false }, discarded: false, autoDiscardable: false, groupId: -1,
                 width: Math.round(p.width), height: Math.round(p.height) }
    }
    function windowInfo(w, populate) {
        if (!w) return null
        const info = { id: w.windowId, focused: w === app.lastActive && w.active, top: w.y, left: w.x, width: w.width, height: w.height,
                       incognito: false, type: "normal", alwaysOnTop: false,
                       state: w.visibility === Window.FullScreen ? "fullscreen" : w.visibility === Window.Maximized ? "maximized"
                            : w.visibility === Window.Minimized ? "minimized" : "normal" }
        if (populate) info.tabs = w.tabs.filter(t => !t.isPrivate).map(tabInfo)
        return info
    }
    function popupWindowInfo(p, populate) {
        const info = { id: p.windowId, focused: p.active, top: p.y, left: p.x, width: p.width, height: p.height,
                       incognito: false, type: "popup", alwaysOnTop: false, state: "normal" }
        if (populate) info.tabs = [popupTabInfo(p)]
        return info
    }

    // Chrome match patterns ("*://*.example.com/*", "<all_urls>").
    function matchPattern(p, url) {
        if (p === "<all_urls>" || p === "*") return /^(https?|wss?|file|ftp):/.test(url)
        const m = /^(\*|[a-z-]+):\/\/([^/]*)(\/.*)?$/.exec(p)
        const u = /^([a-z-]+):\/\/([^/:]*)(?::\d+)?(\/[^#]*)?/i.exec(url)
        if (!m || !u) return false
        if (m[1] === "*" ? !/^https?$/.test(u[1]) : m[1] !== u[1]) return false
        const h = m[2], host = u[2]
        if (!(h === "*" || h === host || (h.startsWith("*.") && (host === h.slice(2) || host.endsWith(h.slice(1)))))) return false
        const path = new RegExp("^" + (m[3] || "/*").replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$")
        return path.test(u[3] || "/")
    }
    function matchAny(patterns, url) {
        if (!patterns) return false
        const list = Array.isArray(patterns) ? patterns : [patterns]
        return list.some(p => matchPattern(p, url))
    }
    function globMatch(glob, text) {
        const re = new RegExp("^" + glob.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$")
        return re.test(text || "")
    }

    // ------------------------------------------------------------ frames
    function framesOf(t) {
        // [{frame, id, parentId, path}], the main frame first.
        const out = []
        if (!t || !t.view) return out
        const ids = frameIds[t.tabId] || (frameIds[t.tabId] = {})
        const walk = (frame, path, parentId) => {
            let id = 0
            if (path !== "") {
                const key = path + "|" + frame.url
                if (ids[key] === undefined) ids[key] = ++lastFrameId
                id = ids[key]
            }
            out.push({ frame: frame, id: id, parentId: parentId, url: frame.url.toString() })
            const children = frame.children || []
            for (let i = 0; i < children.length; i++) walk(children[i], path + "/" + i, id)
        }
        walk(t.view.mainFrame, "", -1)
        return out
    }
    function runIn(frame, code) {
        return new Promise(resolve => {
            let done = false
            frame.runJavaScript(code, r => { if (!done) { done = true; resolve(r) } })
            later(2000, () => { if (!done) { done = true; resolve(undefined) } })
        })
    }
    function later(ms, f) {
        const timer = Qt.createQmlObject("import QtQuick; Timer { repeat: false }", hub)
        timer.interval = ms
        timer.triggered.connect(() => { f(); timer.destroy() })
        timer.start()
    }

    // ------------------------------------------------------------ action state
    function actionState(ext) {
        if (!actions[ext]) actions[ext] = { title: null, popup: null, badge: "", color: "#d93025", textColor: "#ffffff", icon: "", enabled: true, tabs: {} }
        return actions[ext]
    }
    function actionValue(ext, key, tabId) {
        const s = actionState(ext)
        const perTab = tabId !== undefined && tabId !== null ? s.tabs[tabId] : null
        if (perTab && perTab[key] !== undefined) return perTab[key]
        return s[key]
    }
    function setAction(ext, details, key, value) {
        const s = actionState(ext)
        if (details && details.tabId !== undefined && details.tabId !== null) {
            if (!s.tabs[details.tabId]) s.tabs[details.tabId] = {}
            s.tabs[details.tabId][key] = value
        } else {
            s[key] = value
        }
        bump()
    }
    function colorString(c) {
        if (Array.isArray(c)) return Qt.rgba(c[0] / 255, c[1] / 255, c[2] / 255, (c[3] === undefined ? 255 : c[3]) / 255).toString()
        return c
    }
    // For the toolbar button of an extension in a tab.
    function badgeText(ext, tab) {
        const id = tab ? tab.tabId : null
        const text = actionValue(ext, "badge", id)
        if (text) return text
        if (tab && browser.dnrCountsOnBadge(ext)) {
            const n = browser.dnrBlockedOn(ext, tab.url)
            return n > 0 ? String(n) : ""
        }
        return ""
    }
    function popupFor(ext, tab) {
        const popup = actionValue(ext, "popup", tab ? tab.tabId : null)
        if (popup !== null && popup !== undefined) return popup
        const info = extensionInfo(ext)
        return info ? (info.popup || info.defaultPopup || "") : ""
    }
    function actionClicked(ext, win, anchor) {
        const tab = win.currentTab
        const popup = popupFor(ext, tab)
        if (popup) win.openExtensionPopup(ext, popup, anchor)
        else send(ext, "action.onClicked", [tabInfo(tab && !tab.isPrivate ? tab : null)])
    }

    // ------------------------------------------------------------ context menus
    function menuItems(ext) { return menus[ext] || [] }
    function setMenus(ext, list) { const m = menus; m[ext] = list; menus = m; bump() }
    function removeMenu(list, id) {
        const gone = new Set([id])
        let changed = true
        while (changed) {
            changed = false
            for (const item of list) if (!gone.has(item.id) && gone.has(item.parentId)) { gone.add(item.id); changed = true }
        }
        return list.filter(item => !gone.has(item.id))
    }
    // Entries for the page's context menu.
    function menuEntries(win, tab, request) {
        if (!tab || tab.isPrivate) return []
        const link = request.linkUrl.toString()
        const src = request.mediaUrl.toString()
        const selection = request.selectedText
        const contexts = new Set(["all"])
        if (link) contexts.add("link")
        if (selection.trim()) contexts.add("selection")
        if (request.isContentEditable) contexts.add("editable")
        if (request.mediaType === ContextMenuRequest.MediaTypeImage) contexts.add("image")
        if (request.mediaType === ContextMenuRequest.MediaTypeVideo) contexts.add("video")
        if (request.mediaType === ContextMenuRequest.MediaTypeAudio) contexts.add("audio")
        if (contexts.size === 1) contexts.add("page")
        const pageUrl = tab.url
        const fits = (item) => {
            if (item.visible === false) return false
            const want = item.contexts && item.contexts.length ? item.contexts : ["page"]
            if (!want.some(c => contexts.has(c))) return false
            if (item.documentUrlPatterns && !matchAny(item.documentUrlPatterns, pageUrl)) return false
            if (item.targetUrlPatterns && (link || src) && !matchAny(item.targetUrlPatterns, link || src)) return false
            return true
        }
        const out = []
        for (const ext of Object.keys(menus)) {
            const info = extensionInfo(ext)
            if (!info || !info.enabled) continue
            const items = menuItems(ext)
            const entry = (item) => {
                if (item.type === "separator") return { separator: true }
                const title = String(item.title || "").replace(/%s/g, selection.length > 30 ? selection.slice(0, 28) + "…" : selection)
                const kids = items.filter(c => c.parentId === item.id && fits(c))
                if (kids.length) return { text: title, image: info.icon, run: () => win.showMenuList([{ header: title }].concat(kids.map(entry)), request) }
                const checked = item.type === "checkbox" || item.type === "radio" ? !!item.checked : undefined
                return {
                    text: (checked ? "✓ " : "") + title, image: info.icon, enabled: item.enabled !== false,
                    run: () => {
                        if (item.type === "checkbox") item.checked = !item.checked
                        if (item.type === "radio") { for (const o of items) if (o.parentId === item.parentId && o.type === "radio") o.checked = false; item.checked = true }
                        send(ext, "contextMenus.onClicked", [{
                            menuItemId: item.id, parentMenuItemId: item.parentId, editable: request.isContentEditable,
                            pageUrl: pageUrl, frameUrl: request.frameUrl ? request.frameUrl.toString() : undefined,
                            linkUrl: link || undefined, srcUrl: src || undefined, selectionText: selection || undefined,
                            mediaType: contexts.has("image") ? "image" : contexts.has("video") ? "video" : contexts.has("audio") ? "audio" : undefined,
                            checked: checked === undefined ? undefined : item.checked, wasChecked: checked
                        }, tabInfo(tab)])
                    }
                }
            }
            const top = items.filter(item => (item.parentId === undefined || item.parentId === null) && fits(item))
            if (!top.length) continue
            if (top.length === 1) out.push(entry(top[0]))
            else out.push({ text: info.name, image: info.icon, run: () => win.showMenuList([{ header: info.name }].concat(top.map(entry)), request) })
        }
        return out
    }

    // ------------------------------------------------------------ content scripts
    function persistScripts() { browser.writeText(stateFile, JSON.stringify(registered)) }
    function applyMainScripts(ext) {
        browser.setExtensionScripts(ext, (registered[ext] || []).filter(s => s.world === "MAIN"))
    }
    function setScripts(ext, list) {
        const r = registered
        r[ext] = list
        registered = r
        persistScripts()
        applyMainScripts(ext)
    }

    // ------------------------------------------------------------ events from the browser
    function tabCreated(t) { if (!t.isPrivate) send("", "tabs.onCreated", [tabInfo(t)]) }
    function tabRemoved(t, w, closing) {
        if (t.isPrivate) return
        delete frameIds[t.tabId]
        send("", "tabs.onRemoved", [t.tabId, { windowId: w.windowId, isWindowClosing: !!closing }])
    }
    function tabActivated(t) {
        if (!t || t.isPrivate) return
        const w = t.browserWindow
        send("", "tabs.onActivated", [{ tabId: t.tabId, windowId: w.windowId }])
        send("", "tabs.onHighlighted", [{ tabIds: [t.tabId], windowId: w.windowId }])
    }
    function tabChanged(t, change) {
        if (t.isPrivate || !t.browserWindow) return
        send("", "tabs.onUpdated", [t.tabId, change, tabInfo(t)])
    }
    function navigation(t, name, url, extra) {
        if (t.isPrivate) return
        if (name === "onBeforeNavigate") delete frameIds[t.tabId]
        const details = Object.assign({ tabId: t.tabId, frameId: 0, parentFrameId: -1, url: url, timeStamp: Date.now(),
                                        processId: -1, documentLifecycle: "active", frameType: "outermost_frame" }, extra || {})
        if (name === "onCommitted" || name === "onHistoryStateUpdated" || name === "onReferenceFragmentUpdated") {
            details.transitionType = details.transitionType || "link"
            details.transitionQualifiers = details.transitionQualifiers || []
        }
        send("", "webNavigation." + name, [details])
    }
    function windowCreated(w) { send("", "windows.onCreated", [windowInfo(w, false)]) }
    function windowRemoved(w) { send("", "windows.onRemoved", [w.windowId]) }
    function windowFocused(w) { send("", "windows.onFocusChanged", [w ? w.windowId : -1]) }

    // ------------------------------------------------------------ the API
    readonly property var handlers: ({
        // ---- tabs
        "tabs.query": function (ext, a) {
            const q = a[0] || {}
            const current = app.lastActive
            let list = allTabs()
            if (q.active !== undefined) list = list.filter(t => (t.browserWindow.currentTab === t) === q.active)
            if (q.highlighted !== undefined) list = list.filter(t => (t.browserWindow.currentTab === t) === q.highlighted)
            if (q.currentWindow !== undefined) list = list.filter(t => (t.browserWindow === current) === q.currentWindow)
            if (q.lastFocusedWindow !== undefined) list = list.filter(t => (t.browserWindow === current) === q.lastFocusedWindow)
            if (q.windowId !== undefined) { const w = hub.windowById(q.windowId); list = list.filter(t => t.browserWindow === w) }
            if (q.pinned !== undefined) list = list.filter(t => t.pinned === q.pinned)
            if (q.audible !== undefined) list = list.filter(t => t.audible === q.audible)
            if (q.muted !== undefined) list = list.filter(t => t.muted === q.muted)
            if (q.discarded !== undefined) list = list.filter(t => t.sleeping === q.discarded)
            if (q.status) list = list.filter(t => (t.loading ? "loading" : "complete") === q.status)
            if (q.index !== undefined) list = list.filter(t => t.browserWindow.tabs.indexOf(t) === q.index)
            if (q.title) list = list.filter(t => hub.globMatch(q.title, t.title))
            if (q.url) list = list.filter(t => hub.matchAny(q.url, t.url))
            if (q.windowType && q.windowType !== "normal") list = []
            return list.map(hub.tabInfo)
        },
        "tabs.get": function (ext, a) {
            const p = a[0] !== undefined && a[0] !== null ? hub.popupById(a[0]) : null
            if (p && p.tabId === a[0]) return hub.popupTabInfo(p)
            return hub.tabInfo(hub.needTab(a[0]))
        },
        "tabs.getCurrent": function (ext, a, ctx) {
            const t = hub.allTabs().find(x => x.url === ctx.url)
            return t ? hub.tabInfo(t) : undefined
        },
        "tabs.create": function (ext, a) {
            const p = a[0] || {}
            const w = hub.windowById(p.windowId) || app.lastActive
            if (!w) { const nw = app.newWindow([{ url: p.url || "" }], {}); return hub.tabInfo(nw.tabs[0]) }
            const opener = p.openerTabId !== undefined ? hub.tabById(p.openerTabId) : null
            const t = w.openTab(p.url || "", { background: p.active === false, index: p.index, pinned: !!p.pinned, opener: opener || undefined })
            if (p.active !== false) { w.raise(); w.requestActivate() }
            return hub.tabInfo(t)
        },
        "tabs.update": function (ext, a) {
            const t = hub.needTab(a[0])
            const p = a[1] || {}
            if (p.url) t.load(p.url)
            if (p.active || p.highlighted || p.selected) t.browserWindow.selectTab(t)
            if (p.pinned !== undefined) t.pinned = p.pinned
            if (p.muted !== undefined) t.muted = p.muted
            return hub.tabInfo(t)
        },
        "tabs.remove": function (ext, a) {
            const ids = Array.isArray(a[0]) ? a[0] : [a[0]]
            for (const id of ids) {
                const p = hub.popupById(id)
                if (p && p.tabId === id) { p.close(); continue }
                const t = hub.needTab(id)
                t.browserWindow.closeTab(t)
            }
        },
        "tabs.reload": function (ext, a) { hub.needTab(a[0]).reload(!!(a[1] && a[1].bypassCache)) },
        "tabs.duplicate": function (ext, a) {
            const t = hub.needTab(a[0])
            const w = t.browserWindow
            return hub.tabInfo(w.openTab(t.url, { opener: t, index: w.tabs.indexOf(t) + 1 }))
        },
        "tabs.goBack": function (ext, a) { hub.needTab(a[0]).back() },
        "tabs.goForward": function (ext, a) { hub.needTab(a[0]).forward() },
        "tabs.discard": function (ext, a) { const t = hub.needTab(a[0]); if (t.browserWindow.currentTab !== t) t.sleep(); return hub.tabInfo(t) },
        "tabs.highlight": function (ext, a) {
            const w = hub.windowById((a[0] || {}).windowId)
            const ids = [].concat((a[0] || {}).tabs)
            const t = w ? w.tabs[ids[0]] : null
            if (t) w.selectTab(t)
            return hub.windowInfo(w, true)
        },
        "tabs.move": function (ext, a) {
            const ids = Array.isArray(a[0]) ? a[0] : [a[0]]
            return ids.map(id => hub.tabInfo(hub.needTab(id)))
        },
        "tabs.getZoom": function (ext, a) { return hub.needTab(a[0]).zoom },
        "tabs.setZoom": function (ext, a) { const t = hub.needTab(a[0]); t.setZoom(a[1] > 0 ? a[1] : settings.value("web/zoom")) },
        "tabs.captureVisibleTab": function (ext, a) {
            const w = hub.windowById(a[0])
            const t = w ? w.currentTab : null
            if (!t || !t.view || t.isPrivate) throw new Error("No visible tab.")
            const options = a[1] || {}
            return new Promise((resolve, reject) => {
                const ok = t.view.grabToImage(result => resolve(browser.imageDataUrl(result.image, options.format || "png", options.quality || 0)))
                if (!ok) reject(new Error("Capture impossible."))
            })
        },
        "tabs._identify": function (ext, a) {
            // Which tab and frame a content script is in: the frame whose
            // document carries the one-time mark it set.
            const d = a[0] || {}
            const strip = u => String(u || "").split("#")[0]
            const want = strip(d.url)
            const blank = /^(about:|data:|blob:)/.test(want)
            const checks = []
            for (const t of hub.allTabs()) {
                if (!t.view) continue
                const frames = hub.framesOf(t)
                for (const f of frames) {
                    if (d.top !== (f.id === 0)) continue
                    const url = strip(f.url)
                    if (!(url === want || (blank && (url === "" || /^(about:|data:|blob:)/.test(url))))) continue
                    checks.push(hub.runIn(f.frame, "(document.documentElement && document.documentElement.getAttribute('data-flair-ext')) || ''")
                        .then(r => String(r || "").split(" ").includes(d.nonce) ? { tabId: t.tabId, frameId: f.id, tab: hub.tabInfo(t) } : null))
                }
            }
            return Promise.all(checks).then(results => results.find(r => r) || null)
        },
        // ---- windows
        "windows.get": function (ext, a) {
            const p = hub.popupById(a[0])
            if (p && p.windowId === a[0]) return hub.popupWindowInfo(p, a[1] && a[1].populate)
            const w = hub.windowById(a[0])
            if (!w) throw new Error("No window with id: " + a[0] + ".")
            return hub.windowInfo(w, a[1] && a[1].populate)
        },
        "windows.getCurrent": function (ext, a) { return hub.windowInfo(app.lastActive, a[0] && a[0].populate) },
        "windows.getLastFocused": function (ext, a) { return hub.windowInfo(app.lastActive, a[0] && a[0].populate) },
        "windows.getAll": function (ext, a) {
            const populate = a[0] && a[0].populate
            return hub.windowsList().filter(w => w.tabs.some(t => !t.isPrivate)).map(w => hub.windowInfo(w, populate))
                   .concat(hub.popups.map(p => hub.popupWindowInfo(p, populate)))
        },
        "windows.create": function (ext, a) {
            const d = a[0] || {}
            const urls = d.url === undefined ? [""] : Array.isArray(d.url) ? d.url : [d.url]
            if (d.type === "popup" || d.type === "panel") {
                const p = hub.openWindow(urls[0], d.width, d.height, d.left, d.top)
                return hub.popupWindowInfo(p, true)
            }
            const w = app.newWindow(urls.map(u => ({ url: u })), {})
            if (d.width) w.width = d.width
            if (d.height) w.height = d.height
            if (d.state === "maximized") w.showMaximized()
            else if (d.state === "fullscreen") w.showFullScreen()
            else if (d.state === "minimized") w.showMinimized()
            return hub.windowInfo(w, true)
        },
        "windows.update": function (ext, a) {
            const p = hub.popupById(a[0])
            const d = a[1] || {}
            if (p && p.windowId === a[0]) {
                if (d.focused) { p.raise(); p.requestActivate() }
                if (d.width) p.width = d.width
                if (d.height) p.height = d.height
                if (d.left !== undefined) p.x = d.left
                if (d.top !== undefined) p.y = d.top
                return hub.popupWindowInfo(p, false)
            }
            const w = hub.windowById(a[0])
            if (!w) throw new Error("No window with id: " + a[0] + ".")
            if (d.state === "maximized") w.showMaximized()
            else if (d.state === "fullscreen") w.showFullScreen()
            else if (d.state === "minimized") w.showMinimized()
            else if (d.state === "normal") w.showNormal()
            if (d.width) w.width = d.width
            if (d.height) w.height = d.height
            if (d.focused || d.drawAttention) { w.raise(); w.requestActivate() }
            return hub.windowInfo(w, false)
        },
        "windows.remove": function (ext, a) {
            const p = hub.popupById(a[0])
            if (p && p.windowId === a[0]) { p.close(); return }
            const w = hub.windowById(a[0])
            if (w) w.close()
        },
        // ---- action
        "action.setBadgeText": function (ext, a) { hub.setAction(ext, a[0], "badge", String((a[0] || {}).text || "")) },
        "action.getBadgeText": function (ext, a) { return hub.actionValue(ext, "badge", (a[0] || {}).tabId) || "" },
        "action.setBadgeBackgroundColor": function (ext, a) { hub.setAction(ext, a[0], "color", hub.colorString((a[0] || {}).color)) },
        "action.getBadgeBackgroundColor": function (ext, a) { const c = Qt.color(hub.actionValue(ext, "color", (a[0] || {}).tabId)); return [Math.round(c.r * 255), Math.round(c.g * 255), Math.round(c.b * 255), Math.round(c.a * 255)] },
        "action.setBadgeTextColor": function (ext, a) { hub.setAction(ext, a[0], "textColor", hub.colorString((a[0] || {}).color)) },
        "action.getBadgeTextColor": function (ext, a) { const c = Qt.color(hub.actionValue(ext, "textColor", (a[0] || {}).tabId)); return [Math.round(c.r * 255), Math.round(c.g * 255), Math.round(c.b * 255), Math.round(c.a * 255)] },
        "action.setTitle": function (ext, a) { hub.setAction(ext, a[0], "title", (a[0] || {}).title) },
        "action.getTitle": function (ext, a) { const t = hub.actionValue(ext, "title", (a[0] || {}).tabId); const i = hub.extensionInfo(ext); return t !== null && t !== undefined ? t : (i ? i.actionTitle || i.name : "") },
        "action.setPopup": function (ext, a) { hub.setAction(ext, a[0], "popup", (a[0] || {}).popup || "") },
        "action.getPopup": function (ext, a) { return hub.popupFor(ext, hub.tabById((a[0] || {}).tabId)) || "" },
        "action.setIcon": function (ext, a) {
            const d = a[0] || {}
            let icon = d.dataUrl || d.path || ""
            // QML can't load chrome-extension:// URLs: the file itself.
            const prefix = "chrome-extension://" + ext + "/"
            if (icon.startsWith(prefix)) { const f = browser.extensionFile(ext, icon.slice(prefix.length).split(/[?#]/)[0]); icon = f !== "" ? browser.fileUrl(f) : "" }
            hub.setAction(ext, d, "icon", icon)
        },
        "action.enable": function (ext, a) { hub.setAction(ext, a[0] === undefined ? null : { tabId: a[0] }, "enabled", true) },
        "action.disable": function (ext, a) { hub.setAction(ext, a[0] === undefined ? null : { tabId: a[0] }, "enabled", false) },
        "action.isEnabled": function (ext, a) { return hub.actionValue(ext, "enabled", a[0]) !== false },
        "action.openPopup": function (ext, a) {
            const w = app.lastActive
            const popup = hub.popupFor(ext, w ? w.currentTab : null)
            if (!w || !popup) throw new Error("Aucune fenêtre pour la popup.")
            w.openExtensionPopup(ext, popup, null)
        },
        // ---- context menus
        "contextMenus.create": function (ext, a) {
            const item = a[0] || {}
            const list = hub.menuItems(ext).filter(x => x.id !== item.id)
            list.push(item)
            hub.setMenus(ext, list)
        },
        "contextMenus.update": function (ext, a) {
            const list = hub.menuItems(ext)
            const item = list.find(x => x.id === a[0])
            if (!item) throw new Error("Cannot find menu item with id " + a[0])
            Object.assign(item, a[1] || {})
            hub.setMenus(ext, list)
        },
        "contextMenus.remove": function (ext, a) { hub.setMenus(ext, hub.removeMenu(hub.menuItems(ext), a[0])) },
        "contextMenus.removeAll": function (ext) { hub.setMenus(ext, []) },
        // ---- scripting
        "scripting.executeMain": function (ext, a) {
            const d = a[0] || {}
            const target = d.target || {}
            const t = hub.needTab(target.tabId)
            let frames = hub.framesOf(t)
            if (!target.allFrames) frames = frames.filter(f => (target.frameIds && target.frameIds.length ? target.frameIds : [0]).includes(f.id))
            let code = ""
            if (d.func) code = "(" + d.func + ").apply(null, " + JSON.stringify(d.args || []) + ")"
            else {
                // Only the extension's own files (never "../" outside its folder).
                for (const file of d.files || []) {
                    const path = browser.extensionFile(ext, String(file))
                    if (path === "") throw new Error("Could not load file: '" + file + "'.")
                    code += browser.readExtensionFile(ext, String(file)) + "\n;\n"
                }
            }
            return Promise.all(frames.map(f => hub.runIn(f.frame, code).then(r => ({ frameId: f.id, documentId: t.tabId + ":" + f.id, result: r === undefined ? null : r }))))
        },
        "scripting.registerContentScripts": function (ext, a) {
            const list = (hub.registered[ext] || []).slice()
            for (const s of a[0] || []) {
                if (list.some(x => x.id === s.id)) throw new Error("Duplicate script ID '" + s.id + "'")
                list.push(s)
            }
            hub.setScripts(ext, list)
        },
        "scripting.getRegisteredContentScripts": function (ext, a) {
            const ids = (a[0] || {}).ids
            return (hub.registered[ext] || []).filter(s => !ids || ids.includes(s.id))
        },
        "scripting.unregisterContentScripts": function (ext, a) {
            const ids = (a[0] || {}).ids
            hub.setScripts(ext, ids ? (hub.registered[ext] || []).filter(s => !ids.includes(s.id)) : [])
        },
        "scripting.updateContentScripts": function (ext, a) {
            const list = (hub.registered[ext] || []).slice()
            for (const s of a[0] || []) {
                const i = list.findIndex(x => x.id === s.id)
                if (i < 0) throw new Error("Script with ID '" + s.id + "' does not exist")
                list[i] = Object.assign({}, list[i], s)
            }
            hub.setScripts(ext, list)
        },
        "scripting._matching": function (ext, a) {
            const d = a[0] || {}
            const base = extensionHost.fileBase(ext)
            const js = [], css = []
            for (const s of hub.registered[ext] || []) {
                if (s.world === "MAIN") continue
                if (d.frameId !== 0 && !s.allFrames) continue
                if (!hub.matchAny(s.matches, d.url) || hub.matchAny(s.excludeMatches, d.url)) continue
                if (s.css) for (const c of s.css) css.push(base + String(c).replace(/^\/+/, ""))
                if (s.js && s.js.length)
                    js.push({ url: base + "?files=" + encodeURIComponent(s.js.map(f => String(f).replace(/^\/+/, "")).join(",")),
                              runAt: s.runAt || "document_idle" })
            }
            return { js: js, css: css }
        },
        // ---- webNavigation
        "webNavigation.getAllFrames": function (ext, a) {
            const t = hub.tabById((a[0] || {}).tabId)
            if (!t) return null
            return hub.framesOf(t).map(f => ({ frameId: f.id, parentFrameId: f.parentId, url: f.url, errorOccurred: false,
                                               documentId: t.tabId + ":" + f.id, documentLifecycle: "active",
                                               frameType: f.id === 0 ? "outermost_frame" : "sub_frame" }))
        },
        "webNavigation.getFrame": function (ext, a) {
            const d = a[0] || {}
            const t = hub.tabById(d.tabId)
            if (!t) return null
            const f = hub.framesOf(t).find(x => x.id === (d.frameId || 0))
            return f ? { frameId: f.id, parentFrameId: f.parentId, url: f.url, errorOccurred: false, documentId: t.tabId + ":" + f.id,
                         documentLifecycle: "active", frameType: f.id === 0 ? "outermost_frame" : "sub_frame" } : null
        },
        // ---- storage.session
        "storage.session.get": function (ext, a, ctx, from) {
            const store = (from || hub.session)[ext] || {}
            const keys = a[0]
            if (keys === null || keys === undefined) return Object.assign({}, store)
            const out = {}
            if (typeof keys === "string") { if (keys in store) out[keys] = store[keys] }
            else if (Array.isArray(keys)) { for (const k of keys) if (k in store) out[k] = store[k] }
            else for (const k in keys) out[k] = k in store ? store[k] : keys[k]
            return out
        },
        "storage.session.set": function (ext, a) {
            const store = hub.session[ext] || (hub.session[ext] = {})
            const changes = {}
            for (const k in (a[0] || {})) { changes[k] = { oldValue: store[k], newValue: a[0][k] }; store[k] = a[0][k] }
            hub.send(ext, "storage.session.onChanged", [changes])
        },
        "storage.session.remove": function (ext, a) {
            const store = hub.session[ext] || {}
            const changes = {}
            for (const k of a[0] || []) if (k in store) { changes[k] = { oldValue: store[k] }; delete store[k] }
            hub.send(ext, "storage.session.onChanged", [changes])
        },
        "storage.session.clear": function (ext) { hub.session[ext] = {} },
        "storage.sync.get": function (ext, a) { return hub.handlers["storage.session.get"].call(null, ext, a, {}, hub.syncStore) },
        "storage.sync.set": function (ext, a) {
            const store = hub.syncStore[ext] || (hub.syncStore[ext] = {})
            const changes = {}
            for (const k in (a[0] || {})) { changes[k] = { oldValue: store[k], newValue: a[0][k] }; store[k] = a[0][k] }
            hub.saveSync()
            hub.send(ext, "storage.sync.onChanged", [changes])
        },
        "storage.sync.remove": function (ext, a) {
            const store = hub.syncStore[ext] || {}
            const changes = {}
            for (const k of a[0] || []) if (k in store) { changes[k] = { oldValue: store[k] }; delete store[k] }
            hub.saveSync()
            hub.send(ext, "storage.sync.onChanged", [changes])
        },
        "storage.sync.clear": function (ext) {
            const store = hub.syncStore[ext] || {}
            const changes = {}
            for (const k in store) changes[k] = { oldValue: store[k] }
            hub.syncStore[ext] = {}
            hub.saveSync()
            hub.send(ext, "storage.sync.onChanged", [changes])
        },
        // ---- the rest
        "notifications.create": function (ext, a) {
            const o = a[1] || {}
            browser.notify(o.title || (hub.extensionInfo(ext) || {}).name || "Flair Web", o.message || "", o.iconUrl && o.iconUrl.startsWith("chrome-extension://") ? browser.extensionFile(ext, o.iconUrl.replace(/^chrome-extension:\/\/[^/]+\//, "")) : "")
            return a[0]
        },
        "notifications.clear": function () { return true },
        "cookies.get": function () { return null },
        "cookies.getAll": function () { return [] },
        "cookies.set": function () { return null },
        "cookies.remove": function () { return null },
        "downloads.download": function (ext, a) {
            const w = app.lastActive
            if (!w) throw new Error("Aucune fenêtre.")
            w.openTab((a[0] || {}).url, { background: true })
            return 0
        },
        "identity.launchWebAuthFlow": function (ext, a) {
            const d = a[0] || {}
            const redirect = "https://" + ext + ".chromiumapp.org/"
            return new Promise((resolve, reject) => {
                const p = hub.openWindow(d.url, 520, 680)
                let settled = false
                p.addressChanged.connect(u => {
                    if (!settled && u.startsWith(redirect)) { settled = true; resolve(u); p.close() }
                })
                p.closing.connect(() => { if (!settled) { settled = true; reject(new Error("The user did not approve access.")) } })
            })
        }
    })

    // A small window for an extension page (windows.create type popup, sign-in flows).
    function openWindow(url, width, height, left, top) {
        const p = windowComponent.createObject(null, { appRoot: app, windowId: nextWindowId(), tabId: nextTabId(),
                                                       width: width || 480, height: height || 640 })
        if (left !== undefined) p.x = left
        if (top !== undefined) p.y = top
        p.load(url)
        popups = popups.concat([p])
        p.closing.connect(() => {
            popups = popups.filter(x => x !== p)
            send("", "windows.onRemoved", [p.windowId])
            send("", "tabs.onRemoved", [p.tabId, { windowId: p.windowId, isWindowClosing: true }])
            Qt.callLater(() => p.destroy())
        })
        p.show()
        p.requestActivate()
        return p
    }
}
