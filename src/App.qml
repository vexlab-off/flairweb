import QtQuick
import QtQuick.Window
import QtWebEngine

// The application: its windows, the session they make up, downloads, and
// recently closed tabs. Each window is a BrowserWindow.
QtObject {
    id: app
    property var windows: []
    property var lastActive: null
    property var downloads: []          // live WebEngineDownloadRequest objects
    property var closedTabs: []         // [{url, title, pinned}], newest last
    property bool quitting: false
    property bool firstPageMarked: false

    property Component windowComponent: Component { BrowserWindow {} }
    // The browser's side of the extensions' chrome.* API.
    property Extensions extensions: Extensions { app: app }
    onLastActiveChanged: if (lastActive) extensions.windowFocused(lastActive)
    // Chrome wakes an extension's worker for its events; here a hidden page
    // per extension keeps it running so it hears ours.
    // The extensions with a worker, as a list that changes only when the set
    // does: a new array each time would reload every keeper (and wipe every
    // worker's state) whenever any extension changes.
    property var keptIds: []
    function updateKeptIds() {
        const ids = browser.extensions.filter(e => e.installed && e.enabled && e.hasWorker).map(e => e.id)
        if (ids.join(",") !== keptIds.join(",")) keptIds = ids
    }
    property Connections extensionsWatch: Connections {
        target: browser
        function onExtensionsChanged() { app.updateKeptIds() }
    }
    property Window extensionKeeper: Window {
        visible: false
        width: 16; height: 16
        Repeater {
            model: app.keptIds
            delegate: WebEngineView {
                id: keeper
                required property string modelData
                width: 1; height: 1
                profile: browser.profile
                url: "chrome-extension://" + modelData + "/flair/keepalive.html"
                // The extension may not be switched on yet: try again.
                onLoadingChanged: (info) => { if (info.status === WebEngineView.LoadFailedStatus) retry.start() }
                property Timer retry: Timer { interval: 1500; onTriggered: keeper.reload() }
            }
        }
    }
    property Component popupComponent: Component { PopupWindow {} }


    function opt(key) { return settings.revision, settings.value(key) }

    // tabs: [{url, title, pinned, private}]
    function newWindow(tabs, options) {
        options = options || {}
        const w = windowComponent.createObject(null, { appRoot: app, windowId: extensions.nextWindowId() })
        windows = windows.concat([w])
        extensions.windowCreated(w)
        lastActive = w
        if (options.request) {
            w.openTab("", { request: options.request, private: !!options.private })
        } else if (tabs && tabs.length) {
            // In their saved order, unloaded except the one that was current.
            const current = Math.min(options.current || 0, tabs.length - 1)
            const opened = tabs.map((t, i) => w.openTab(t.url, { title: t.title, pinned: !!t.pinned, private: !!t.private,
                                                                index: w.tabs.length, background: true, noSelect: true,
                                                                lazy: i !== current && t.url !== "" }))
            w.selectTab(opened[current])
        } else {
            w.openTab(options.private ? "" : startPage(), { private: !!options.private })
        }
        w.show()
        w.requestActivate()
        return w
    }

    function startPage() {
        return opt("start/mode") === "home" && opt("start/home") !== "" ? engines.fixUrl(opt("start/home")) : ""
    }

    function openPopup(request, isPrivate) {
        const p = popupComponent.createObject(null, { appRoot: app, isPrivate: isPrivate })
        p.adopt(request)
        p.show()
    }

    // Quitting closes every window in one go: the session is what was open
    // when the first of them closed. Closing one window while the browser
    // keeps running saves the others on the next turn.
    property var closingSnapshot: null
    function windowClosed(w) {
        if (!quitting && closingSnapshot === null) {
            closingSnapshot = windows.map(x => x.sessionData()).filter(x => x.tabs.length > 0)
            Qt.callLater(() => {
                closingSnapshot = null
                if (!quitting && windows.length > 0) saveSession()
            })
        }
        windows = windows.filter(x => x !== w)
        if (lastActive === w) lastActive = windows.length ? windows[windows.length - 1] : null
        if (windows.length === 0) {
            if (!quitting && closingSnapshot !== null) library.saveSession(closingSnapshot)
            quitting = true
        } else if (!quitting) {
            // The window's tabs can come back with Ctrl+Maj+T.
            for (const t of w.sessionData().tabs) pushClosed(t)
        }
        for (const t of w.tabs) extensions.tabRemoved(t, w, true)
        extensions.windowRemoved(w)
        const hadPrivate = w.hasPrivateTabs()
        Qt.callLater(() => w.destroy())
        if (!quitting && hadPrivate && !windows.some(x => x.hasPrivateTabs())) browser.clearPrivateData()
    }
    function quit() {
        saveSession()
        quitting = true
        Qt.quit()
    }

    function pushClosed(entry) {
        const list = closedTabs.concat([entry])
        closedTabs = list.slice(-25)
    }
    function popClosed() {
        if (!closedTabs.length) return null
        const entry = closedTabs[closedTabs.length - 1]
        closedTabs = closedTabs.slice(0, -1)
        return entry
    }

    // ------------------------------------------------------------ session
    property Timer sessionTimer: Timer { interval: 1500; onTriggered: app.saveSession() }
    function sessionChanged() { if (!quitting) sessionTimer.restart() }
    function saveSession() {
        sessionTimer.stop()
        library.saveSession(windows.map(w => w.sessionData()).filter(w => w.tabs.length > 0))
    }

    // ------------------------------------------------------------ downloads
    function handleDownload(download, isPrivate) {
        if (download.isSavePageDownload) {
            download.savePageFormat = WebEngineDownloadRequest.MimeHtmlSaveFormat
            const base = (download.downloadFileName || "page").replace(/\.(html?|mhtml)$/i, "")
            download.downloadFileName = base + ".mhtml"
        }
        download.downloadDirectory = settings.downloadDirectory()
        download.accept()
        downloads = downloads.concat([download])
        const w = lastActive
        if (w) {
            w.flash("Téléchargement : " + download.downloadFileName)
            if (opt("downloads/openPanel")) w.showPanel("downloads", false)
        }
    }
    function handleDownloadFinished(download, isPrivate) {
        const ok = download.state === WebEngineDownloadRequest.DownloadCompleted
        const path = download.downloadDirectory + "/" + download.downloadFileName
        // Private downloads stay on disk but leave no trace in the list.
        if (!isPrivate && (ok || download.state === WebEngineDownloadRequest.DownloadInterrupted))
            library.logDownload({ name: download.downloadFileName, path: path, url: download.url.toString(),
                                  size: download.receivedBytes, ok: ok, finished: Date.now() })
        downloads = downloads.filter(d => d !== download)
        if (ok) {
            if (lastActive) lastActive.flash("Téléchargé : " + download.downloadFileName)
            const after = opt("downloads/after")
            if (after === "open") browser.openFile(path)
            else if (after === "folder") browser.showInFolder(path)
        }
    }
    property Connections profileDownloads: Connections {
        target: browser.profile
        function onDownloadRequested(download) { app.handleDownload(download) }
        function onDownloadFinished(download) { app.handleDownloadFinished(download) }
    }
    property Connections privateDownloads: Connections {
        target: browser.privateProfile
        function onDownloadRequested(download) { app.handleDownload(download, true) }
        function onDownloadFinished(download) { app.handleDownloadFinished(download, true) }
    }

    // A second launch (a link opened from another app) lands here.
    property Connections instance: Connections {
        target: browser
        function onOpenRequested(urls, isPrivate, newWindow) {
            const list = urls.map(u => engines.isUrl(u) ? engines.fixUrl(u) : engines.resolve(u, app.opt("search/engine")).url)
            if (newWindow || !app.lastActive) {
                app.newWindow(list.map(u => ({ url: u, private: isPrivate })), { private: isPrivate })
                return
            }
            const w = app.lastActive
            if (list.length === 0) w.openTab("", { private: isPrivate })
            list.forEach(u => w.openTab(u, { private: isPrivate }))
            w.raise()
            w.requestActivate()
        }
    }

    // The window opens at once; only the restored pages wait for the
    // extensions (at most 3 s, see Browser), so their content scripts reach
    // them. What you open yourself loads right away.
    readonly property bool pagesReady: browser.extensionsReady
    onPagesReadyChanged: if (pagesReady) {
        if (startupLog) browser.startupMark("extensions ready, restored pages start")
        for (const w of windows) if (w.currentTab) w.currentTab.ensureStarted()
    }
    property bool started: false
    Component.onCompleted: { updateKeptIds(); start() }
    function start() {
        if (started) return
        started = true
        if (startupLog) browser.startupMark("first window created")
        const fromArgs = browser.startUrls.map(u => ({ url: engines.isUrl(u) ? engines.fixUrl(u) : engines.resolve(u, opt("search/engine")).url, private: browser.startPrivate }))
        const session = opt("start/mode") === "session" ? library.session() : []
        if (session.length > 0 && !browser.startPrivate) {
            session.forEach((s, i) => {
                const tabs = s.tabs.slice()
                let current = s.current || 0
                if (i === 0 && fromArgs.length) { current = tabs.length; fromArgs.forEach(t => tabs.push(t)) }
                newWindow(tabs, { current: current })
            })
        } else if (fromArgs.length) {
            newWindow(fromArgs, { private: browser.startPrivate })
        } else {
            newWindow([], { private: browser.startPrivate })
        }
    }
}
