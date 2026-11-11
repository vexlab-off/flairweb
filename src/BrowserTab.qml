import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine

// One tab: the new tab page until an address is opened, then a web view
// created on demand (restored tabs stay unloaded until they are shown).
Item {
    id: tab
    anchors.fill: parent
    visible: current
    property var browserWindow: null
    property bool isPrivate: false
    property bool pinned: false
    property string initialUrl: ""
    property string savedTitle: ""
    property real lastActive: Date.now()
    property var opener: null
    property int tabId: 0
    property string lastLoadedUrl: ""
    // Extensions hear about this tab (never about private ones).
    readonly property var extensionsHub: browserWindow && browserWindow.appRoot ? browserWindow.appRoot.extensions : null
    function tellExtensions(change) { if (extensionsHub && !isPrivate) extensionsHub.tabChanged(tab, change) }
    function navigationEvent(name, url, extra) { if (extensionsHub && !isPrivate) extensionsHub.navigation(tab, name, url, extra) }
    onTitleChanged: tellExtensions({ title: title })
    onIconChanged: if (icon !== "") tellExtensions({ favIconUrl: icon })
    onAudibleChanged: tellExtensions({ audible: audible })
    onPinnedChanged: tellExtensions({ pinned: pinned })
    onSleepingChanged: tellExtensions({ discarded: sleeping })
    property bool muted: false
    property int blocked: 0
    property string hoveredLink: ""
    property var findResult: ({ count: 0, active: 0 })
    property var permissions: []     // waiting for an answer, oldest first
    readonly property var permission: permissions.length ? permissions[0] : null
    function answerPermission(grant) {
        const p = permission
        permissions = permissions.slice(1)
        if (p) { if (grant) p.grant(); else p.deny() }
    }
    property var certificateError: null
    property string crashMessage: ""
    property bool readerOpen: false

    readonly property var view: web.item
    readonly property bool started: web.active && web.item !== null
    readonly property string url: view ? view.url.toString() : initialUrl
    readonly property bool isNewTab: !web.active && initialUrl === ""
    readonly property string title: {
        if (view && view.title && view.title !== url) return view.title
        if (savedTitle) return savedTitle
        if (isNewTab) return isPrivate ? "Onglet privé" : "Nouvel onglet"
        const m = /^[a-z]+:\/\/(?:www\.)?([^\/:?#]+)/i.exec(url)
        return m ? m[1] : url
    }
    readonly property string icon: view ? view.icon.toString() : ""
    readonly property bool loading: view ? view.loading : false
    readonly property real progress: view ? view.loadProgress / 100 : 0
    readonly property bool canGoBack: view ? view.canGoBack : false
    readonly property bool canGoForward: view ? view.canGoForward : false
    readonly property bool audible: view ? view.recentlyAudible : false
    readonly property real zoom: view ? view.zoomFactor : 1
    readonly property bool sleeping: view !== null && view.lifecycleState !== WebEngineView.LifecycleState.Active
    readonly property string security: url.startsWith("https:") ? "secure" : url.startsWith("http:") ? "insecure"
                                     : url.startsWith("file:") ? "file" : ""
    readonly property bool current: browserWindow !== null && browserWindow.currentTab === tab

    function opt(key) { return settings.revision, settings.value(key) }

    // ------------------------------------------------------------ actions
    // Restored and background pages start once the extensions are ready.
    function ensureStarted() {
        const root = browserWindow ? browserWindow.appRoot : null
        if (root && !root.pagesReady) return
        if (!web.active && initialUrl !== "") web.active = true
    }
    function load(address) {
        if (!address) return
        readerOpen = false
        if (!web.active) {
            initialUrl = address
            web.active = true
        } else {
            view.url = address
        }
        // From the new tab page (its box, a shortcut): the keyboard goes to
        // the page, not to the hidden field.
        if (current) Qt.callLater(() => { if (view && current) view.forceActiveFocus() })
    }
    // A page that asked for a new window opens here (keeps window.opener).
    function adopt(request) {
        web.active = true
        request.openIn(web.item)
    }
    function reload(hard) {
        if (!view) return
        crashMessage = ""
        if (hard) view.reloadAndBypassCache(); else view.reload()
    }
    function stop() { if (view) view.stop() }
    function back() { if (view) view.goBack() }
    function forward() { if (view) view.goForward() }
    function wake() {
        if (view && view.lifecycleState !== WebEngineView.LifecycleState.Active)
            view.lifecycleState = WebEngineView.LifecycleState.Active
    }
    // First frozen, then (on a later call, once Chromium allows it)
    // discarded: the page's memory is freed; it reloads when shown again.
    function sleep() {
        if (!view || current || audible || view.lifecycleState === WebEngineView.LifecycleState.Discarded) return
        view.lifecycleState = view.recommendedState === WebEngineView.LifecycleState.Discarded
            ? WebEngineView.LifecycleState.Discarded : WebEngineView.LifecycleState.Frozen
    }
    function setZoom(factor) {
        if (!view) return
        const f = Math.max(0.25, Math.min(5, Math.round(factor * 100) / 100))
        view.zoomFactor = f
        if (!isPrivate) library.setZoom(url, Math.abs(f - opt("web/zoom")) < 0.001 ? 0 : f)
    }
    function applyZoom() {
        if (!view) return
        const site = library.zoomFor(url)
        const wanted = site > 0 ? site : opt("web/zoom")
        if (Math.abs(view.zoomFactor - wanted) > 0.001) view.zoomFactor = wanted
    }
    function toggleMute() { muted = !muted }
    function find(text, backward) {
        if (!view) return
        view.findText(text, backward ? WebEngineView.FindBackward : 0)
    }
    function stopFind() { if (view) view.findText("") }
    // The page's readable text, for the assistant.
    function pageText(callback) {
        if (!view) { callback(""); return }
        view.runJavaScript("(function(){var s=window.getSelection?String(window.getSelection()):'';" +
                           "return {text:(document.body?document.body.innerText:'')||'', selection:s};})()",
                           (r) => callback(r ? r.text : "", r ? r.selection : ""))
    }

    onCurrentChanged: if (current) { lastActive = Date.now(); ensureStarted(); wake() }
    onMutedChanged: {
        if (view) view.audioMuted = muted
        tellExtensions({ mutedInfo: { muted: muted } })
    }

    // ------------------------------------------------------------ Chrome Web Store
    // The store's page (see extension/store.js) shows "Ajouter à Flair Web"
    // and learns here which extensions are installed.
    readonly property bool onStore: /^https:\/\/chromewebstore\.google\.com\//.test(url)
    function syncStore() {
        if (!view || !onStore) return
        const ids = browser.extensions.filter(e => e.installed).map(e => e.id)
        try { const t = JSON.parse(opt("appearance/chromeTheme") || "null"); if (t && t.id) ids.push(t.id) } catch (e) {}
        view.runJavaScript("document.documentElement.setAttribute('data-flairweb-installed', " + JSON.stringify(ids.join(",")) + ");" +
                           "document.documentElement.setAttribute('data-flairweb-installing', " + (browser.installing ? "'1'" : "''") + ");")
    }
    Connections {
        target: browser
        enabled: tab.onStore
        function onExtensionsChanged() { tab.syncStore() }
        function onInstallingChanged() { tab.syncStore() }
        function onExtensionMessage(message) { tab.syncStore() }
    }
    // A request from the store's button: only for the extension of the page.
    function storeMessage(message) {
        const marker = "__flairweb_store__:install:"
        if (!onStore || !message.startsWith(marker)) return false
        const id = message.slice(marker.length)
        if (/^[a-p]{32}$/.test(id) && browser.storeExtensionId(url.split(/[?#]/)[0]) === id) {
            if (browser.extensions.some(e => e.id === id && e.installed) || opt("appearance/chromeTheme").indexOf(id) >= 0) browserWindow.flash("Déjà installé.")
            // Flair Web asks, in its own bar: the page alone never installs anything.
            else storeRequest = { id: id, name: (title || "").replace(/\s*\S\s*Chrome Web Store\s*$/i, "") || id }
        }
        syncStore()
        return true
    }
    property var storeRequest: null
    onUrlChanged: if (storeRequest && browser.storeExtensionId(url.split(/[?#]/)[0]) !== storeRequest.id) storeRequest = null
    function answerStore(install) {
        const r = storeRequest
        storeRequest = null
        if (install && r) browser.installFromStore(r.id)
        syncStore()
    }

    Connections {
        target: shield
        function onBlocked(host) {
            if (tab.view) tab.blocked = shield.blockedOn(tab.url)
        }
    }

    // ------------------------------------------------------------ content
    NewTabPage {
        anchors.fill: parent
        visible: tab.isNewTab
        owner: tab
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        visible: web.active

        // Questions the page asks, above it.
        Banner {
            Layout.fillWidth: true
            visible: tab.permission !== null
            icon: tab.permission ? tab.browserWindow.permissionIcon(tab.permission.permissionType) : "info"
            text: tab.permission ? "<b>" + tab.browserWindow.hostOf(tab.permission.origin.toString()) + "</b> demande " + tab.browserWindow.permissionLabel(tab.permission.permissionType) + "." : ""
            actions: [
                { text: "Refuser", run: () => tab.answerPermission(false) },
                { text: "Autoriser", primary: true, run: () => tab.answerPermission(true) }
            ]
        }
        Banner {
            // The Web Store's "Ajouter à Flair Web".
            Layout.fillWidth: true
            visible: tab.storeRequest !== null
            icon: "puzzle"
            text: tab.storeRequest ? "Ajouter <b>" + tab.storeRequest.name.replace(/&/g, "&amp;").replace(/</g, "&lt;") + "</b> à Flair Web ? Une extension peut lire et modifier les pages que tu visites ; un thème change seulement les couleurs." : ""
            actions: [
                { text: "Annuler", run: () => tab.answerStore(false) },
                { text: "Ajouter", primary: true, run: () => tab.answerStore(true) }
            ]
        }
        Banner {
            Layout.fillWidth: true
            visible: tab.certificateError !== null
            tone: "danger"
            icon: "lock"
            text: tab.certificateError ? "<b>Connexion non sécurisée.</b> " + tab.certificateError.description : ""
            actions: (tab.certificateError && tab.certificateError.overridable
                      ? [{ text: "Continuer quand même", run: () => { tab.certificateError.acceptCertificate(); tab.certificateError = null } }] : [])
                     .concat([{ text: "Revenir en sécurité", primary: true, run: () => { tab.certificateError.rejectCertificate(); tab.certificateError = null } }])
        }
        Banner {
            // Google's "unusual traffic" page: it often takes Qt WebEngine
            // browsers for robots. Ticking the box works; so does asking
            // another engine the same question.
            id: sorryBanner
            Layout.fillWidth: true
            readonly property string query: {
                const m = /^https:\/\/(www\.)?google\.[a-z.]+\/sorry\/.*[?&]continue=([^&#]+)/.exec(tab.url)
                if (!m) return "\u0000"
                const q = /[?&]q=([^&#]*)/.exec(decodeURIComponent(m[2]))
                return q ? decodeURIComponent(q[1].replace(/\+/g, " ")) : ""
            }
            function searchWith(key) {
                tab.load(query !== "" ? engines.searchUrl(key, query) : engines.homeUrl(key))
            }
            visible: query !== "\u0000"
            icon: "alert"
            text: "<b>Google te prend pour un robot.</b> Il le fait souvent avec les navigateurs basés sur Qt WebEngine. Coche la case, ou pose la question ailleurs :"
            actions: [
                { text: "Startpage", run: () => sorryBanner.searchWith("startpage") },
                { text: "DuckDuckGo", run: () => sorryBanner.searchWith("duckduckgo") },
                { text: "Changer de moteur…", primary: true, run: () => tab.browserWindow.openSettings("search") }
            ]
        }
        Banner {
            Layout.fillWidth: true
            visible: tab.crashMessage !== ""
            tone: "danger"
            icon: "alert"
            text: tab.crashMessage
            actions: [{ text: "Recharger", primary: true, run: () => tab.reload(false) }]
        }

        Loader {
            id: web
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: false
            sourceComponent: WebEngineView {
                id: view
                profile: tab.isPrivate ? browser.privateProfile : browser.profile
                backgroundColor: "white"
                audioMuted: tab.muted
                settings.javascriptEnabled: tab.opt("web/javascript")
                settings.autoLoadImages: tab.opt("web/images")
                settings.forceDarkMode: tab.opt("web/forceDark")
                settings.playbackRequiresUserGesture: !tab.opt("web/autoplay")
                settings.pdfViewerEnabled: tab.opt("web/pdf")
                settings.pluginsEnabled: tab.opt("web/pdf")
                settings.webGLEnabled: tab.opt("web/webgl")
                settings.showScrollBars: tab.opt("web/scrollbars")
                settings.scrollAnimatorEnabled: tab.opt("web/smoothScroll")
                settings.spatialNavigationEnabled: tab.opt("web/spatialNavigation")
                settings.dnsPrefetchEnabled: tab.opt("web/dnsPrefetch") && !tab.isPrivate
                settings.javascriptCanAccessClipboard: tab.opt("web/clipboard")
                settings.javascriptCanPaste: tab.opt("web/clipboard")
                settings.fullScreenSupportEnabled: true
                settings.screenCaptureEnabled: true
                settings.localStorageEnabled: true
                settings.focusOnNavigationEnabled: false
                settings.hyperlinkAuditingEnabled: false
                settings.allowRunningInsecureContent: false
                settings.navigateOnDropEnabled: true

                Component.onCompleted: {
                    if (tab.initialUrl !== "") url = tab.initialUrl
                }

                onUrlChanged: {
                    tab.tellExtensions({ url: url.toString() })
                    // A change without a load: pushState or a #fragment.
                    if (!loading) tab.navigationEvent(url.toString().split("#")[0] === tab.lastLoadedUrl.split("#")[0] ? "onReferenceFragmentUpdated" : "onHistoryStateUpdated", url.toString())
                    tab.blocked = shield.blockedOn(url.toString())
                    tab.applyZoom()
                    tab.crashMessage = ""
                }
                onLoadingChanged: (info) => {
                    const address = info.url.toString()
                    if (info.status === WebEngineView.LoadStartedStatus) {
                        tab.navigationEvent("onBeforeNavigate", address)
                        tab.tellExtensions({ status: "loading", url: address })
                        tab.navigationEvent("onCommitted", address)
                    } else if (info.status === WebEngineView.LoadSucceededStatus) {
                        tab.lastLoadedUrl = address
                        tab.navigationEvent("onDOMContentLoaded", address)
                        tab.navigationEvent("onCompleted", address)
                        tab.tellExtensions({ status: "complete" })
                    } else if (info.status === WebEngineView.LoadFailedStatus) {
                        tab.navigationEvent("onErrorOccurred", address, { error: "net::ERR_FAILED" })
                        tab.tellExtensions({ status: "complete" })
                    }
                    if (info.status === WebEngineView.LoadStartedStatus) {
                        for (const p of tab.permissions) p.deny()
                        tab.permissions = []
                        tab.certificateError = null
                        tab.applyZoom()
                    } else if (info.status === WebEngineView.LoadFailedStatus && shield.upgradeFailed(info.url.toString())) {
                        // HTTPS only: this site has no working https, go back to http.
                        view.url = info.url.toString().replace(/^https:/, "http:")
                    } else if (info.status === WebEngineView.LoadSucceededStatus) {
                        if (startupLog && !tab.browserWindow.appRoot.firstPageMarked) { tab.browserWindow.appRoot.firstPageMarked = true; browser.startupMark("first page loaded: " + address) }
                        tab.applyZoom()
                        tab.syncStore()
                        if (!tab.isPrivate && tab.opt("privacy/history"))
                            library.visit(view.url.toString(), view.title)
                        tab.savedTitle = ""
                    }
                }
                onTitleChanged: if (!tab.isPrivate && tab.opt("privacy/history")) library.updateTitle(url.toString(), title)
                onJavaScriptConsoleMessage: (level, message, lineNumber, sourceID) => {
                    if (!tab.storeMessage(message) && browser.traceExtensions) console.log("[page]", message, sourceID + ":" + lineNumber)
                }
                onIconChanged: if (!tab.isPrivate && icon.toString() !== "") favicons.remember(url.toString(), icon.toString())
                onLinkHovered: (hoveredUrl) => tab.hoveredLink = hoveredUrl.toString()
                onNewWindowRequested: (request) => tab.browserWindow.openFromRequest(request, tab)
                onFullScreenRequested: (request) => {
                    request.accept()
                    tab.browserWindow.setPageFullScreen(request.toggleOn, tab)
                }
                onPermissionRequested: (permission) => {
                    if (tab.opt("privacy/permissions") === "deny") { permission.deny(); return }
                    tab.permissions = tab.permissions.concat([permission])
                }
                onCertificateError: (error) => {
                    error.defer()
                    tab.certificateError = error
                }
                onContextMenuRequested: (request) => {
                    request.accepted = true
                    tab.browserWindow.showContextMenu(tab, request)
                }
                onFindTextFinished: (result) => tab.findResult = { count: result.numberOfMatches, active: result.activeMatch }
                onWindowCloseRequested: tab.browserWindow.closeTab(tab)
                onRenderProcessTerminated: (status, code) => {
                    if (status !== WebEngineView.NormalTerminationStatus)
                        tab.crashMessage = "La page s'est arrêtée (" + (status === WebEngineView.CrashedTerminationStatus ? "plantage" : status === WebEngineView.KilledTerminationStatus ? "processus tué" : "fin anormale") + ")."
                }
                onPdfPrintingFinished: (filePath, success) => tab.browserWindow.flash(success ? "PDF enregistré : " + filePath : "Le PDF n'a pas pu être enregistré.")
                onPrintRequested: tab.browserWindow.savePdf(tab)
            }
        }
    }

    Loader {
        anchors.fill: parent
        active: tab.readerOpen
        sourceComponent: ReaderView { owner: tab }
    }
}
