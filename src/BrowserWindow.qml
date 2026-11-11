import QtQuick
import QtQml
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtWebEngine

// A browser window: tabs (on the side or on top), the toolbar with the
// address bar, the page, and the panels around it.
ApplicationWindow {
    id: win
    property var appRoot: null
    property int windowId: 0
    readonly property var extensionsHub: appRoot ? appRoot.extensions : null
    property var tabs: []
    property var currentTab: null
    property bool panelOpen: false
    property string panelSection: "bookmarks"
    property bool devtoolsOpen: false
    property bool zen: false
    property bool pageFullScreen: false
    property var fullScreenTab: null
    property int visibilityBeforeFullScreen: Window.Windowed
    readonly property var closedTabs: appRoot ? appRoot.closedTabs : []
    readonly property alias menu: flairMenu

    width: 1400
    height: 900
    minimumWidth: 640
    minimumHeight: 420
    visible: false
    title: (currentTab ? currentTab.title + " — " : "") + "Flair Web"
    color: theme.sidebar

    Material.theme: theme.isDark ? Material.Dark : Material.Light
    Material.accent: theme.highlight
    Material.background: theme.surface
    Material.foreground: theme.text

    function opt(key) { return settings.revision, settings.value(key) }
    readonly property bool sideTabs: opt("tabs/position") === "side"
    readonly property bool chromeVisible: !pageFullScreen && !zen
    readonly property real cardMargin: opt("appearance/pageCard") && chromeVisible ? 8 : 0
    readonly property bool compactUi: opt("appearance/density") === "compact"
    readonly property string barMode: opt("toolbar/bookmarksBar")
    readonly property bool bookmarksBarVisible: chromeVisible && (barMode === "always" || (barMode === "newtab" && currentTab !== null && currentTab.isNewTab))

    onActiveChanged: if (active && appRoot) appRoot.lastActive = win
    // FLAIRWEB_STARTUP_LOG: the first picture on screen.
    property bool firstFrame: false
    onFrameSwapped: if (!firstFrame) {
        firstFrame = true
        if (startupLog) browser.startupMark("first frame of a window")
    }
    onClosing: (close) => {
        if (appRoot && !appRoot.quitting && appRoot.windows.length > 1 && tabs.length > 1 && opt("tabs/confirmCloseMany") && !confirmClose.confirmed) {
            close.accepted = false
            confirmClose.open()
            return
        }
        if (appRoot) appRoot.windowClosed(win)
    }

    // ------------------------------------------------------------ helpers
    function hostOf(url) {
        const m = /^[a-z\-]+:\/\/(?:www\.)?([^\/:?#]+)/i.exec(url || "")
        return m ? m[1] : (url || "")
    }
    function flash(text) { toast.show(text) }
    function hasPrivateTabs() { return tabs.some(t => t.isPrivate) }
    function sessionData() {
        const kept = tabs.filter(t => !t.isPrivate && !t.isNewTab)
        return { tabs: kept.map(t => ({ url: t.url, title: t.title, pinned: t.pinned })),
                 current: Math.max(0, kept.indexOf(currentTab)) }
    }
    function sessionChanged() { if (appRoot) appRoot.sessionChanged() }

    // ------------------------------------------------------------ tabs
    Component { id: tabComponent; BrowserTab {} }

    // opts: {private, pinned, background, lazy, title, request, opener, index}
    function openTab(url, opts) {
        opts = opts || {}
        const isPrivate = opts.private !== undefined ? !!opts.private : (opts.opener ? opts.opener.isPrivate : false)
        const tab = tabComponent.createObject(pageHost, {
            browserWindow: win, isPrivate: isPrivate, pinned: !!opts.pinned, tabId: extensionsHub ? extensionsHub.nextTabId() : 0,
            initialUrl: opts.request ? "" : (url || ""), savedTitle: opts.title || "",
            opener: opts.opener || null
        })
        const pinnedCount = tabs.filter(t => t.pinned).length
        let index = tabs.length
        if (opts.index !== undefined) index = opts.index
        else if (currentTab && (opts.opener || opts.request || (url && opt("tabs/newTabPosition") === "afterCurrent"))) {
            index = tabs.indexOf(currentTab) + 1
            // Links opened one after another from the same page keep their order.
            while (index < tabs.length && tabs[index].opener === currentTab) index++
        }
        index = tab.pinned ? Math.min(index, pinnedCount) : Math.max(index, pinnedCount)
        const list = tabs.slice()
        list.splice(index, 0, tab)
        tabs = list
        if (extensionsHub) extensionsHub.tabCreated(tab)
        if (opts.request) tab.adopt(opts.request)
        else if (url && !opts.lazy) tab.ensureStarted()
        if (!opts.noSelect && (!opts.background || !currentTab)) selectTab(tab)
        if (!url && !opts.request && !opts.background) Qt.callLater(() => address.focusWith("", ""))
        sessionChanged()
        return tab
    }

    function selectTab(tab) {
        if (!tab || tabs.indexOf(tab) < 0) return
        if (fullScreenTab && fullScreenTab !== tab) leavePageFullScreen()
        if (currentTab && currentTab !== tab) currentTab.lastActive = Date.now()
        const changed = currentTab !== tab
        currentTab = tab
        if (changed && extensionsHub) extensionsHub.tabActivated(tab)
        findBar.close()
        if (!tab.isNewTab) Qt.callLater(() => { if (tab.view && !address.editing) tab.view.forceActiveFocus() })
        sessionChanged()
    }

    function closeTab(tab) {
        const i = tabs.indexOf(tab)
        if (i < 0) return
        if (!tab.isPrivate && !tab.isNewTab && appRoot) appRoot.pushClosed({ url: tab.url, title: tab.title, pinned: tab.pinned })
        if (fullScreenTab === tab) leavePageFullScreen()
        const list = tabs.slice()
        list.splice(i, 1)
        let next = currentTab
        if (tab === currentTab) {
            next = tab.opener && list.indexOf(tab.opener) >= 0 && tab.opener.lastActive > 0 ? tab.opener : list[Math.min(i, list.length - 1)]
        }
        tabs = list
        for (const t of list) if (t.opener === tab) t.opener = null
        // The last private tab anywhere: its cookies and cache are forgotten.
        const lastPrivate = tab.isPrivate && !list.some(t => t.isPrivate) && appRoot && !appRoot.windows.some(w => w !== win && w.hasPrivateTabs())
        if (list.length === 0) {
            currentTab = null
            if (opt("tabs/closeWindowWithLastTab")) {
                if (extensionsHub) extensionsHub.tabRemoved(tab, win, true)
                tab.destroy()
                if (lastPrivate) Qt.callLater(browser.clearPrivateData)
                win.close()
                return
            }
            openTab("", {})
        } else {
            selectTab(next)
        }
        if (lastPrivate) Qt.callLater(browser.clearPrivateData)
        if (extensionsHub) extensionsHub.tabRemoved(tab, win, false)
        tab.destroy()
        sessionChanged()
    }

    function nextTab(step) {
        if (tabs.length < 2) return
        const i = tabs.indexOf(currentTab)
        selectTab(tabs[(i + step + tabs.length) % tabs.length])
    }
    function tabAt(n) {
        if (n < 0) selectTab(tabs[tabs.length - 1])
        else if (n < tabs.length) selectTab(tabs[n])
    }
    function moveTabBefore(tab, target) {
        if (!tab || tab === target) return
        const list = tabs.filter(t => t !== tab)
        let index = target ? list.indexOf(target) : list.length
        const pinnedCount = list.filter(t => t.pinned).length
        index = tab.pinned ? Math.min(index, pinnedCount) : Math.max(index, pinnedCount)
        list.splice(index, 0, tab)
        tabs = list
        sessionChanged()
    }
    function moveTab(tab, step) {
        const i = tabs.indexOf(tab)
        const j = i + step
        if (i < 0 || j < 0 || j >= tabs.length) return
        moveTabBefore(tab, step > 0 ? tabs[j + 1] || null : tabs[j])
    }
    function pinTab(tab, pinned) {
        tab.pinned = pinned
        moveTabBefore(tab, pinned ? tabs.find(t => t.pinned && t !== tab) || tabs[0] : tabs.find(t => !t.pinned && t !== tab) || null)
        if (!pinned) moveTabBefore(tab, tabs.find(t => !t.pinned && t !== tab) || null)
    }
    function duplicateTab(tab) { openTab(tab.url, { private: tab.isPrivate, opener: tab, background: false }) }
    function reopenClosed() {
        const entry = appRoot ? appRoot.popClosed() : null
        if (entry) openTab(entry.url, { title: entry.title, pinned: entry.pinned })
    }
    function closeOthers(keep) { for (const t of tabs.slice()) if (t !== keep && !t.pinned) closeTab(t) }
    function closeRight(from) {
        const i = tabs.indexOf(from)
        for (const t of tabs.slice(i + 1)) if (!t.pinned) closeTab(t)
    }
    function sleepOthers() {
        for (const t of tabs) if (t !== currentTab) t.sleep()
        flash("Les autres onglets dorment : la mémoire est libérée.")
    }

    // Opens an address: here, in a new tab, or a new window.
    function openAddress(url, where) {
        if (where === "tab" || (where !== "here" && !currentTab)) { openTab(url, { private: currentTab ? currentTab.isPrivate : false }); return }
        if (where === "window") { const p = currentTab ? currentTab.isPrivate : false; appRoot.newWindow([{ url: url, private: p }], { private: p }); return }
        if (!currentTab) { openTab(url, {}); return }
        currentTab.load(url)
        currentTab.view && currentTab.view.forceActiveFocus()
    }

    // A page asked for a new tab or window (a link with target=_blank,
    // window.open, a middle click).
    function openFromRequest(request, opener, privateOverride) {
        const isPrivate = privateOverride !== undefined ? privateOverride : (opener ? opener.isPrivate : false)
        switch (request.destination) {
        case WebEngineNewWindowRequest.InNewBackgroundTab:
            openTab("", { request: request, opener: opener, background: opt("tabs/backgroundLinks"), private: isPrivate })
            break
        case WebEngineNewWindowRequest.InNewWindow:
            appRoot.newWindow([], { request: request, private: isPrivate })
            break
        case WebEngineNewWindowRequest.InNewDialog:
            appRoot.openPopup(request, isPrivate)
            break
        default:
            openTab("", { request: request, opener: opener, private: isPrivate })
        }
    }

    function focusAddress(text, engineKey) { address.focusWith(text, engineKey) }
    function showPanel(section, toggle) {
        if (toggle && panelOpen && panelSection === section) { panelOpen = false; return }
        panelSection = section
        panelOpen = true
    }
    function openSettings(section, extra) { settingsDialog.openAt(section || "appearance", extra || "") }
    function zoom(step) {
        if (!currentTab || !currentTab.view) return
        const levels = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
        const z = currentTab.zoom
        let i = levels.findIndex(l => l >= z - 0.001)
        if (i < 0) i = levels.length - 1
        if (step > 0) i = levels[i] > z + 0.001 ? i : Math.min(levels.length - 1, i + 1)
        else i = Math.max(0, levels[i] < z - 0.001 ? i : i - 1)
        currentTab.setZoom(levels[i])
    }
    function bookmarkCurrent() {
        const t = currentTab
        if (!t || t.isNewTab) return
        if (library.isBookmarked(t.url)) { editBookmark(t.url); return }
        library.addBookmark(t.url, t.title, "")
        flash("Ajouté aux favoris. Ctrl+D à nouveau pour le modifier.")
    }
    function editBookmark(url) { bookmarkEditor.edit(url) }
    function savePdf(tab) {
        tab = tab || currentTab
        if (!tab || !tab.view) return
        const name = (tab.title || "page").replace(/[\/\\:*?"<>|]+/g, " ").trim().slice(0, 80) || "page"
        const path = browser.uniquePath(settings.downloadDirectory(), name + ".pdf")
        tab.view.printToPdf(path)
        flash("Enregistrement en PDF…")
    }
    // Ends a page's fullscreen (a video), for the page and the window.
    function leavePageFullScreen() {
        const t = fullScreenTab
        fullScreenTab = null
        if (t && t.view && t.view.isFullScreen) t.view.fullScreenCancelled()
        setPageFullScreen(false)
    }
    function setPageFullScreen(on, tab) {
        if (tab !== undefined) fullScreenTab = on ? tab : null
        if (on && !pageFullScreen) {
            visibilityBeforeFullScreen = win.visibility
            pageFullScreen = true
            win.showFullScreen()
        } else if (!on && pageFullScreen) {
            pageFullScreen = false
            if (visibilityBeforeFullScreen === Window.Maximized) win.showMaximized(); else win.showNormal()
        }
    }
    function toggleFullScreen() {
        if (pageFullScreen) {
            leavePageFullScreen()
        } else {
            setPageFullScreen(true)
        }
    }
    function openDownloaded(path) { browser.openFile(path) }
    function askAssistant(prompt) {
        showPanel("assistant", false)
        Qt.callLater(() => sidePanel.ask(prompt))
    }
    function viewSource() { if (currentTab && !currentTab.isNewTab) openTab("view-source:" + currentTab.url, { opener: currentTab }) }
    function toggleDevtools() { devtoolsOpen = !devtoolsOpen && currentTab !== null && currentTab.view !== null }
    function goHome() {
        const home = opt("start/home")
        if (home) openAddress(engines.fixUrl(home), "here"); else openTab("", {})
    }

    // ------------------------------------------------------------ permissions
    function permissionName(type) {
        switch (type) {
        case WebEnginePermission.PermissionType.MediaAudioCapture: return "Micro"
        case WebEnginePermission.PermissionType.MediaVideoCapture: return "Caméra"
        case WebEnginePermission.PermissionType.MediaAudioVideoCapture: return "Caméra et micro"
        case WebEnginePermission.PermissionType.DesktopVideoCapture: return "Partage d'écran"
        case WebEnginePermission.PermissionType.DesktopAudioVideoCapture: return "Partage d'écran et du son"
        case WebEnginePermission.PermissionType.MouseLock: return "Capture de la souris"
        case WebEnginePermission.PermissionType.Notifications: return "Notifications"
        case WebEnginePermission.PermissionType.Geolocation: return "Position"
        case WebEnginePermission.PermissionType.ClipboardReadWrite: return "Presse-papiers"
        case WebEnginePermission.PermissionType.LocalFontsAccess: return "Polices installées"
        }
        return "Autorisation"
    }
    function permissionLabel(type) {
        switch (type) {
        case WebEnginePermission.PermissionType.MediaAudioCapture: return "à utiliser ton micro"
        case WebEnginePermission.PermissionType.MediaVideoCapture: return "à utiliser ta caméra"
        case WebEnginePermission.PermissionType.MediaAudioVideoCapture: return "à utiliser ta caméra et ton micro"
        case WebEnginePermission.PermissionType.DesktopVideoCapture: return "à voir ton écran"
        case WebEnginePermission.PermissionType.DesktopAudioVideoCapture: return "à voir ton écran et entendre le son"
        case WebEnginePermission.PermissionType.MouseLock: return "à capturer la souris"
        case WebEnginePermission.PermissionType.Notifications: return "à t'envoyer des notifications"
        case WebEnginePermission.PermissionType.Geolocation: return "à connaître ta position"
        case WebEnginePermission.PermissionType.ClipboardReadWrite: return "à lire et écrire le presse-papiers"
        case WebEnginePermission.PermissionType.LocalFontsAccess: return "à voir tes polices installées"
        }
        return "une autorisation"
    }
    function permissionIcon(type) {
        switch (type) {
        case WebEnginePermission.PermissionType.MediaAudioCapture: return "mic"
        case WebEnginePermission.PermissionType.MediaVideoCapture:
        case WebEnginePermission.PermissionType.MediaAudioVideoCapture: return "video"
        case WebEnginePermission.PermissionType.DesktopVideoCapture:
        case WebEnginePermission.PermissionType.DesktopAudioVideoCapture: return "desktop"
        case WebEnginePermission.PermissionType.Notifications: return "bell"
        case WebEnginePermission.PermissionType.Geolocation: return "location"
        case WebEnginePermission.PermissionType.ClipboardReadWrite: return "copy"
        case WebEnginePermission.PermissionType.LocalFontsAccess: return "type"
        }
        return "info"
    }

    // ------------------------------------------------------------ menus
    function showTabMenu(tab, x, y) {
        const i = tabs.indexOf(tab)
        menu.show([
            { text: "Nouvel onglet à côté", icon: "plus", run: () => openTab("", { index: i + 1 }) },
            { text: "Recharger", icon: "refresh", enabled: tab.started, run: () => tab.reload(false) },
            { text: "Dupliquer", icon: "copy", enabled: !tab.isNewTab, run: () => duplicateTab(tab) },
            { text: tab.pinned ? "Détacher" : "Épingler", icon: "pin", run: () => pinTab(tab, !tab.pinned) },
            { text: tab.muted ? "Remettre le son" : "Couper le son", icon: tab.muted ? "volume" : "mute", run: () => tab.toggleMute() },
            { text: "Mettre en veille", icon: "sleep", enabled: tab !== currentTab && tab.started && !tab.sleeping, run: () => tab.sleep() },
            { text: "Copier l'adresse", icon: "link", enabled: !tab.isNewTab, run: () => browser.copy(tab.url) },
            { text: "Ajouter aux favoris", icon: "star", enabled: !tab.isNewTab && !library.isBookmarked(tab.url), run: () => library.addBookmark(tab.url, tab.title, "") },
            { text: "Ouvrir dans une nouvelle fenêtre", icon: "window", enabled: !tab.isNewTab, run: () => { const u = tab.url, p = tab.isPrivate; closeTab(tab); appRoot.newWindow([{ url: u, private: p }], { private: p }) } },
            { separator: true },
            { text: "Fermer les autres onglets", icon: "close", enabled: tabs.length > 1, run: () => closeOthers(tab) },
            { text: "Fermer les onglets à droite", icon: "arrowRight", enabled: i < tabs.length - 1, run: () => closeRight(tab) },
            { text: "Fermer", icon: "close", shortcut: "Ctrl+W", danger: true, run: () => closeTab(tab) }
        ], x, y)
    }

    function showContextMenu(tab, request) {
        const view = tab.view
        const p = view.mapToItem(null, request.position.x, request.position.y)
        const items = []
        const link = request.linkUrl.toString()
        const media = request.mediaUrl.toString()
        const selection = request.selectedText.trim()
        const engine = engines.engine(opt(tab.isPrivate ? "search/privateEngine" : "search/engine"))
        const act = (action) => () => view.triggerWebAction(action)

        if (link !== "") {
            items.push({ text: "Ouvrir dans un nouvel onglet", icon: "plus", run: () => openTab(link, { opener: tab, background: opt("tabs/backgroundLinks") }) })
            items.push({ text: "Ouvrir dans un onglet privé", icon: "mask", run: () => openTab(link, { private: true }) })
            items.push({ text: "Ouvrir dans une nouvelle fenêtre", icon: "window", run: () => appRoot.newWindow([{ url: link, private: tab.isPrivate }], {}) })
            items.push({ text: "Copier l'adresse du lien", icon: "link", run: () => browser.copy(link) })
            items.push({ text: "Enregistrer le lien sous…", icon: "download", run: act(WebEngineView.DownloadLinkToDisk) })
            if (!tab.isPrivate) items.push({ text: "Ajouter aux favoris", icon: "star", enabled: !library.isBookmarked(link), run: () => library.addBookmark(link, request.linkText || link, "") })
            items.push({ separator: true })
        }
        if (request.mediaType === ContextMenuRequest.MediaTypeImage) {
            items.push({ text: "Ouvrir l'image dans un nouvel onglet", icon: "image", run: () => openTab(media, { opener: tab, background: true }) })
            items.push({ text: "Copier l'image", icon: "copy", run: act(WebEngineView.CopyImageToClipboard) })
            items.push({ text: "Copier l'adresse de l'image", icon: "link", run: act(WebEngineView.CopyImageUrlToClipboard) })
            items.push({ text: "Enregistrer l'image", icon: "download", run: act(WebEngineView.DownloadImageToDisk) })
            items.push({ separator: true })
        } else if (request.mediaType === ContextMenuRequest.MediaTypeVideo || request.mediaType === ContextMenuRequest.MediaTypeAudio) {
            items.push({ text: "Lecture / pause", icon: "play", run: act(WebEngineView.ToggleMediaPlayPause) })
            items.push({ text: "Son / muet", icon: "volume", run: act(WebEngineView.ToggleMediaMute) })
            items.push({ text: "Lire en boucle", icon: "refresh", run: act(WebEngineView.ToggleMediaLoop) })
            items.push({ text: "Afficher les commandes", icon: "sliders", run: act(WebEngineView.ToggleMediaControls) })
            items.push({ text: "Copier l'adresse du média", icon: "link", run: act(WebEngineView.CopyMediaUrlToClipboard) })
            items.push({ text: "Enregistrer le média", icon: "download", run: act(WebEngineView.DownloadMediaToDisk) })
            items.push({ separator: true })
        }
        if (request.isContentEditable) {
            items.push({ text: "Annuler", icon: "undo", shortcut: "Ctrl+Z", enabled: !!(request.editFlags & ContextMenuRequest.CanUndo), run: act(WebEngineView.Undo) })
            items.push({ text: "Rétablir", icon: "refresh", shortcut: "Ctrl+Maj+Z", enabled: !!(request.editFlags & ContextMenuRequest.CanRedo), run: act(WebEngineView.Redo) })
            items.push({ text: "Couper", icon: "pencil", shortcut: "Ctrl+X", enabled: !!(request.editFlags & ContextMenuRequest.CanCut), run: act(WebEngineView.Cut) })
            items.push({ text: "Copier", icon: "copy", shortcut: "Ctrl+C", enabled: !!(request.editFlags & ContextMenuRequest.CanCopy), run: act(WebEngineView.Copy) })
            items.push({ text: "Coller", icon: "clone", shortcut: "Ctrl+V", enabled: !!(request.editFlags & ContextMenuRequest.CanPaste), run: act(WebEngineView.Paste) })
            items.push({ text: "Coller sans mise en forme", icon: "texte", shortcut: "Ctrl+Maj+V", enabled: !!(request.editFlags & ContextMenuRequest.CanPaste), run: act(WebEngineView.PasteAndMatchStyle) })
            items.push({ text: "Tout sélectionner", icon: "check", shortcut: "Ctrl+A", run: act(WebEngineView.SelectAll) })
            items.push({ separator: true })
        } else if (selection !== "") {
            const short = selection.length > 28 ? selection.slice(0, 26) + "…" : selection
            items.push({ text: "Copier", icon: "copy", shortcut: "Ctrl+C", run: act(WebEngineView.Copy) })
            if (engines.isUrl(selection)) items.push({ text: "Ouvrir « " + short + " »", icon: "arrowRight", run: () => openTab(engines.fixUrl(selection), { opener: tab }) })
            items.push({ text: "Rechercher « " + short + " » avec " + engine.name, engine: engine,
                         run: () => openTab(engines.searchUrl(engine.key, selection), { opener: tab }) })
            items.push({ text: "Rechercher avec…", icon: "search", run: () => {
                const list = [{ header: "Rechercher « " + short + " » avec" }]
                for (const e of engines.all()) list.push({ text: e.name, engine: e, shortcut: e.keyword,
                                                          run: ((k) => () => openTab(engines.searchUrl(k, selection), { opener: tab }))(e.key) })
                menu.show(list, p.x, p.y)
            } })
            items.push({ text: "Expliquer avec l'assistant", icon: "sparkle", run: () => askAssistant("Explique ce passage de la page, avec son contexte :\n\n« " + selection + " »") })
            items.push({ text: "Traduire avec l'assistant", icon: "globe", run: () => askAssistant("Traduis en français, fidèlement :\n\n" + selection) })
            items.push({ separator: true })
        }
        if (link === "" && selection === "" && !request.isContentEditable && request.mediaType === ContextMenuRequest.MediaTypeNone) {
            items.push({ text: "Précédente", icon: "arrowLeft", shortcut: "Alt+←", enabled: tab.canGoBack, run: () => tab.back() })
            items.push({ text: "Suivante", icon: "arrowRight", shortcut: "Alt+→", enabled: tab.canGoForward, run: () => tab.forward() })
            items.push({ text: "Recharger", icon: "refresh", shortcut: "F5", run: () => tab.reload(false) })
            items.push({ separator: true })
            items.push({ text: "Mode lecture", icon: "book", shortcut: "F9", run: () => tab.readerOpen = true })
            items.push({ text: "Résumer avec l'assistant", icon: "sparkle", run: () => askAssistant("Résume cette page en quelques paragraphes courts, puis donne la conclusion en une phrase.") })
            items.push({ text: "Enregistrer en PDF", icon: "printer", shortcut: "Ctrl+P", run: () => savePdf(tab) })
            items.push({ text: "Enregistrer la page", icon: "download", shortcut: "Ctrl+S", run: act(WebEngineView.SavePage) })
            items.push({ text: "Code source", icon: "code", shortcut: "Ctrl+U", run: () => viewSource() })
            items.push({ separator: true })
        }
        const fromExtensions = extensionsHub ? extensionsHub.menuEntries(win, tab, request) : []
        if (fromExtensions.length) items.push(...fromExtensions, { separator: true })
        items.push({ text: "Inspecter", icon: "bug", shortcut: "F12", run: () => { devtoolsOpen = true; Qt.callLater(() => view.triggerWebAction(WebEngineView.InspectElement)) } })
        menuPoint = p
        menu.show(items, p.x, p.y)
    }
    property point menuPoint: Qt.point(0, 0)
    // A submenu opened from the page's menu (extensions' items).
    function showMenuList(list) { menu.show(list, menuPoint.x, menuPoint.y) }

    // ------------------------------------------------------------ extensions
    function openExtensionPopup(ext, url, anchor) {
        extensionsPopup.showPopup(ext, url, anchor || (extensionsButton.visible ? extensionsButton : mainMenuButton))
    }
    function showExtensionMenu(info, anchor) {
        menu.showBelow(anchor, [
            { header: info.name },
            { text: "Options", icon: "sliders", enabled: !!info.optionsPage, run: () => openTab("chrome-extension://" + info.id + "/" + info.optionsPage, {}) },
            { text: "Désactiver", icon: "close", run: () => browser.setExtensionEnabled(info.id, false) },
            { text: "Désinstaller", icon: "trash", danger: true, run: () => browser.uninstallExtension(info.id) },
            { separator: true },
            { text: "Gérer les extensions", icon: "puzzle", run: () => openSettings("extensions") }
        ])
    }

    function showMainMenu(anchor) {
        menu.showBelow(anchor, [
            { text: "Nouvel onglet", icon: "plus", shortcut: "Ctrl+T", run: () => openTab("", {}) },
            { text: "Onglet privé", icon: "mask", shortcut: "Ctrl+Maj+N", run: () => openTab("", { private: true }) },
            { text: "Nouvelle fenêtre", icon: "window", shortcut: "Ctrl+N", run: () => appRoot.newWindow([], {}) },
            { separator: true },
            { text: "Favoris", icon: "star", shortcut: "Ctrl+Maj+O", run: () => showPanel("bookmarks", false) },
            { text: "Historique", icon: "clock", shortcut: "Ctrl+H", run: () => showPanel("history", false) },
            { text: "Téléchargements", icon: "download", shortcut: "Ctrl+J", run: () => showPanel("downloads", false) },
            { text: "Assistant", icon: "sparkle", shortcut: "Ctrl+Maj+A", run: () => showPanel("assistant", false) },
            { separator: true },
            { text: "Rechercher dans la page", icon: "search", shortcut: "Ctrl+F", enabled: currentTab && currentTab.started, run: () => findBar.show() },
            { text: "Mode lecture", icon: "book", shortcut: "F9", enabled: currentTab && currentTab.started, run: () => currentTab.readerOpen = !currentTab.readerOpen },
            { text: "Enregistrer en PDF", icon: "printer", shortcut: "Ctrl+P", enabled: currentTab && currentTab.started, run: () => savePdf() },
            { text: "Mode zen", icon: "leaf", shortcut: "Ctrl+Maj+F", checked: zen, run: () => zen = !zen },
            { text: "Outils de développement", icon: "bug", shortcut: "F12", checked: devtoolsOpen, run: () => toggleDevtools() },
            { separator: true },
            { text: "Toutes les commandes", icon: "keyboard", shortcut: "Ctrl+Maj+P", run: () => palette.show("") },
            { text: "Réglages", icon: "sliders", shortcut: "Ctrl+,", run: () => openSettings("appearance") },
            { text: "À propos de Flair Web", icon: "info", run: () => about.open() },
            { text: "Quitter", icon: "close", shortcut: "Ctrl+Q", run: () => appRoot.quit() }
        ], true)
    }

    // ------------------------------------------------------------ commands
    readonly property bool hasPage: currentTab !== null && currentTab.started
    readonly property var commands: [
        // Tabs
        { id: "newTab", category: "Onglets", name: "Nouvel onglet", description: "Ouvrir la page de nouvel onglet", shortcut: "Ctrl+T", sequence: "Ctrl+T", run: () => openTab("", {}) },
        { id: "privateTab", category: "Onglets", name: "Onglet privé", description: "Rien n'est gardé : historique, cookies, cache", shortcut: "Ctrl+Maj+N", sequence: "Ctrl+Shift+N", run: () => openTab("", { private: true }) },
        { id: "newWindow", category: "Onglets", name: "Nouvelle fenêtre", description: "Ouvrir une autre fenêtre", shortcut: "Ctrl+N", sequence: "Ctrl+N", run: () => appRoot.newWindow([], {}) },
        { id: "closeTab", category: "Onglets", name: "Fermer l'onglet", description: "Fermer l'onglet courant", shortcut: "Ctrl+W", sequences: ["Ctrl+W", "Ctrl+F4"], run: () => closeTab(currentTab) },
        { id: "reopen", category: "Onglets", name: "Rouvrir l'onglet fermé", description: "Le dernier onglet fermé revient", shortcut: "Ctrl+Maj+T", sequence: "Ctrl+Shift+T", run: () => reopenClosed() },
        { id: "nextTab", category: "Onglets", name: "Onglet suivant", description: "Passer à l'onglet suivant", shortcut: "Ctrl+Tab", sequences: ["Ctrl+Tab", "Ctrl+PgDown"], run: () => nextTab(1) },
        { id: "prevTab", category: "Onglets", name: "Onglet précédent", description: "Revenir à l'onglet précédent", shortcut: "Ctrl+Maj+Tab", sequences: ["Ctrl+Shift+Tab", "Ctrl+PgUp", "Ctrl+Shift+Backtab"], run: () => nextTab(-1) },
        { id: "moveRight", category: "Onglets", name: "Déplacer l'onglet après", description: "Décaler l'onglet d'un cran", shortcut: "Ctrl+Maj+PgDown", sequence: "Ctrl+Shift+PgDown", run: () => moveTab(currentTab, 1) },
        { id: "moveLeft", category: "Onglets", name: "Déplacer l'onglet avant", description: "Décaler l'onglet d'un cran", shortcut: "Ctrl+Maj+PgUp", sequence: "Ctrl+Shift+PgUp", run: () => moveTab(currentTab, -1) },
        { id: "pin", category: "Onglets", name: "Épingler / détacher l'onglet", description: "Les onglets épinglés restent en tête, en icônes", run: () => pinTab(currentTab, !currentTab.pinned), enabled: () => currentTab !== null },
        { id: "duplicate", category: "Onglets", name: "Dupliquer l'onglet", description: "Ouvrir la même page à côté", shortcut: "Alt+Maj+D", sequence: "Alt+Shift+D", run: () => duplicateTab(currentTab), enabled: () => currentTab && !currentTab.isNewTab },
        { id: "mute", category: "Onglets", name: "Couper / remettre le son", description: "Le son de l'onglet courant", shortcut: "Ctrl+M", sequence: "Ctrl+M", run: () => currentTab.toggleMute(), enabled: () => currentTab !== null },
        { id: "sleepOthers", category: "Onglets", name: "Endormir les autres onglets", description: "Libérer la mémoire des onglets en arrière-plan", run: () => sleepOthers() },
        { id: "closeOthers", category: "Onglets", name: "Fermer les autres onglets", description: "Garder seulement l'onglet courant et les épinglés", run: () => closeOthers(currentTab) },
        // Navigation
        { id: "address", category: "Navigation", name: "Barre d'adresse", description: "Taper une adresse ou une recherche", shortcut: "Ctrl+L", sequences: ["Ctrl+L", "F6", "Alt+D"], run: () => focusAddress("", "") },
        { id: "search", category: "Navigation", name: "Rechercher sur le web", description: "Choisir le moteur pour une recherche", shortcut: "Ctrl+K", sequences: ["Ctrl+K", "Ctrl+E"], run: () => { focusAddress("", ""); Qt.callLater(() => address.showEngineMenu(address)) } },
        { id: "back", category: "Navigation", name: "Page précédente", description: "Revenir en arrière", shortcut: "Alt+←", sequences: ["Alt+Left", "Back"], run: () => currentTab.back(), enabled: () => currentTab && currentTab.canGoBack },
        { id: "forward", category: "Navigation", name: "Page suivante", description: "Aller en avant", shortcut: "Alt+→", sequences: ["Alt+Right", "Forward"], run: () => currentTab.forward(), enabled: () => currentTab && currentTab.canGoForward },
        { id: "reload", category: "Navigation", name: "Recharger", description: "Recharger la page", shortcut: "F5", sequences: ["F5", "Ctrl+R"], run: () => currentTab.reload(false), enabled: () => hasPage },
        { id: "hardReload", category: "Navigation", name: "Recharger sans le cache", description: "Tout retélécharger", shortcut: "Ctrl+Maj+R", sequences: ["Ctrl+Shift+R", "Ctrl+F5", "Shift+F5"], run: () => currentTab.reload(true), enabled: () => hasPage },
        { id: "home", category: "Navigation", name: "Accueil", description: "La page d'accueil choisie, ou un nouvel onglet", shortcut: "Alt+Origine", sequence: "Alt+Home", run: () => goHome() },
        // Page
        { id: "find", category: "Page", name: "Rechercher dans la page", description: "Trouver du texte dans la page", shortcut: "Ctrl+F", sequence: "Ctrl+F", run: () => findBar.show(), enabled: () => hasPage },
        { id: "findNext", category: "Page", name: "Résultat suivant", description: "Occurrence suivante", shortcut: "F3", sequences: ["F3", "Ctrl+G"], run: () => findBar.next(false), enabled: () => hasPage },
        { id: "findPrev", category: "Page", name: "Résultat précédent", description: "Occurrence précédente", shortcut: "Maj+F3", sequences: ["Shift+F3", "Ctrl+Shift+G"], run: () => findBar.next(true), enabled: () => hasPage },
        { id: "zoomIn", category: "Page", name: "Zoom avant", description: "Agrandir la page (retenu pour le site)", shortcut: "Ctrl+=", sequences: ["Ctrl+=", "Ctrl++", "Ctrl+Shift+="], run: () => zoom(1), enabled: () => hasPage },
        { id: "zoomOut", category: "Page", name: "Zoom arrière", description: "Réduire la page (retenu pour le site)", shortcut: "Ctrl+-", sequence: "Ctrl+-", run: () => zoom(-1), enabled: () => hasPage },
        { id: "zoomReset", category: "Page", name: "Zoom par défaut", description: "Revenir au zoom choisi dans les réglages", shortcut: "Ctrl+0", sequence: "Ctrl+0", run: () => currentTab.setZoom(opt("web/zoom")), enabled: () => hasPage },
        { id: "reader", category: "Page", name: "Mode lecture", description: "L'article seul, dans une colonne calme", shortcut: "F9", sequences: ["F9", "Ctrl+Alt+R"], run: () => currentTab.readerOpen = !currentTab.readerOpen, enabled: () => hasPage },
        { id: "pdf", category: "Page", name: "Enregistrer en PDF", description: "Dans le dossier des téléchargements", shortcut: "Ctrl+P", sequence: "Ctrl+P", run: () => savePdf(), enabled: () => hasPage },
        { id: "savePage", category: "Page", name: "Enregistrer la page", description: "Une archive .mhtml, lisible hors ligne", shortcut: "Ctrl+S", sequence: "Ctrl+S", run: () => currentTab.view.triggerWebAction(WebEngineView.SavePage), enabled: () => hasPage },
        { id: "source", category: "Page", name: "Code source", description: "Le HTML de la page dans un onglet", shortcut: "Ctrl+U", sequence: "Ctrl+U", run: () => viewSource(), enabled: () => hasPage },
        { id: "devtools", category: "Page", name: "Outils de développement", description: "Inspecteur, console, réseau", shortcut: "F12", sequences: ["F12", "Ctrl+Shift+I"], run: () => toggleDevtools(), enabled: () => hasPage },
        { id: "copyUrl", category: "Page", name: "Copier l'adresse", description: "L'adresse de la page dans le presse-papiers", shortcut: "Ctrl+Maj+C", sequence: "Ctrl+Shift+C", run: () => { browser.copy(currentTab.url); flash("Adresse copiée.") }, enabled: () => currentTab && !currentTab.isNewTab },
        { id: "bookmark", category: "Page", name: "Ajouter aux favoris", description: "La page ouverte (à nouveau : la modifier)", shortcut: "Ctrl+D", sequence: "Ctrl+D", run: () => bookmarkCurrent(), enabled: () => currentTab && !currentTab.isNewTab },
        { id: "toDial", category: "Page", name: "Ajouter aux raccourcis", description: "Une tuile sur la page de nouvel onglet", run: () => { library.addDial(currentTab.url, currentTab.title); flash("Ajouté aux raccourcis.") }, enabled: () => currentTab && !currentTab.isNewTab },
        { id: "darkSites", category: "Page", name: "Mode sombre des sites", description: "Assombrir toutes les pages (forcé)", shortcut: "Alt+Maj+N", sequence: "Alt+Shift+N", run: () => { settings.set("web/forceDark", !opt("web/forceDark")); flash(opt("web/forceDark") ? "Sites en mode sombre." : "Sites dans leurs couleurs.") } },
        { id: "shieldSite", category: "Page", name: "Bouclier sur ce site", description: "Activer ou couper le blocage des pubs ici", run: () => { const off = shield.isAllowed(currentTab.url); shield.setAllowed(currentTab.url, !off); currentTab.reload(false) }, enabled: () => hasPage },
        // Panels and view
        { id: "bookmarks", category: "Panneaux", name: "Favoris", description: "Le panneau des favoris", shortcut: "Ctrl+Maj+O", sequences: ["Ctrl+Shift+O", "Ctrl+Shift+B"], run: () => showPanel("bookmarks", true) },
        { id: "history", category: "Panneaux", name: "Historique", description: "Les pages visitées, par jour", shortcut: "Ctrl+H", sequence: "Ctrl+H", run: () => showPanel("history", true) },
        { id: "downloads", category: "Panneaux", name: "Téléchargements", description: "En cours et terminés", shortcut: "Ctrl+J", sequence: "Ctrl+J", run: () => showPanel("downloads", true) },
        { id: "assistant", category: "Panneaux", name: "Assistant", description: "Résumer, expliquer, questionner la page avec l'IA", shortcut: "Ctrl+Maj+A", sequence: "Ctrl+Shift+A", run: () => showPanel("assistant", true) },
        { id: "summarize", category: "Panneaux", name: "Résumer la page", description: "L'assistant résume la page ouverte", run: () => askAssistant("Résume cette page en quelques paragraphes courts, puis donne la conclusion en une phrase."), enabled: () => hasPage },
        { id: "bar", category: "Affichage", name: "Barre de favoris", description: "Toujours, sur les nouveaux onglets, ou jamais", shortcut: "Ctrl+Maj+Espace", sequence: "Ctrl+Shift+Space", run: () => settings.set("toolbar/bookmarksBar", barMode === "always" ? "never" : barMode === "never" ? "newtab" : "always") },
        { id: "compactTabs", category: "Affichage", name: "Onglets compacts", description: "Les onglets verticaux en icônes seules", shortcut: "Ctrl+B", sequence: "Ctrl+B", run: () => settings.set("tabs/compact", !opt("tabs/compact")) },
        { id: "tabsPosition", category: "Affichage", name: "Onglets en haut / sur le côté", description: "Changer la place des onglets", run: () => settings.set("tabs/position", sideTabs ? "top" : "side") },
        { id: "zen", category: "Affichage", name: "Mode zen", description: "La page seule ; Ctrl+L montre encore l'adresse, Ctrl+Maj+F en sort", shortcut: "Ctrl+Maj+F", sequence: "Ctrl+Shift+F", run: () => zen = !zen },
        { id: "fullscreen", category: "Affichage", name: "Plein écran", description: "La page sur tout l'écran", shortcut: "F11", sequence: "F11", run: () => toggleFullScreen() },
        { id: "theme", category: "Affichage", name: "Clair / sombre", description: "Basculer le mode de l'interface", run: () => settingsDialog.setMode(theme.isDark ? "light" : "dark") },
        // App
        { id: "palette", category: "Application", name: "Toutes les commandes", description: "Chercher une commande ou un onglet", shortcut: "Ctrl+Maj+P", sequence: "Ctrl+Shift+P", run: () => palette.show("") },
        { id: "settings", category: "Application", name: "Réglages", description: "Apparence, recherche, confidentialité, IA…", shortcut: "Ctrl+,", sequence: "Ctrl+,", run: () => openSettings("appearance") },
        { id: "searchSettings", category: "Application", name: "Réglages : moteurs de recherche", description: "Choisir, ajouter, donner des mots-clés", run: () => openSettings("search") },
        { id: "privacySettings", category: "Application", name: "Réglages : confidentialité", description: "Bouclier, cookies, données", run: () => openSettings("privacy") },
        { id: "styleSettings", category: "Application", name: "Réglages : styles et scripts", description: "CSS et JavaScript, partout ou par site", run: () => openSettings("style") },
        { id: "keys", category: "Application", name: "Raccourcis clavier", description: "Tous les raccourcis", shortcut: "F1", sequence: "F1", run: () => openSettings("keys") },
        { id: "about", category: "Application", name: "À propos", description: "Version, moteur, navigateur par défaut", run: () => about.open() },
        { id: "quit", category: "Application", name: "Quitter", description: "Fermer Flair Web (la session est gardée)", shortcut: "Ctrl+Q", sequence: "Ctrl+Q", run: () => appRoot.quit() }
    ]

    Instantiator {
        model: win.commands.filter(c => c.sequence || c.sequences)
        delegate: Shortcut {
            required property var modelData
            sequences: modelData.sequences || [modelData.sequence]
            context: Qt.WindowShortcut
            enabled: !modelData.enabled || modelData.enabled()
            onActivated: modelData.run()
        }
    }
    // Ctrl+1…8: that tab, Ctrl+9: the last.
    Instantiator {
        model: 9
        delegate: Shortcut {
            required property int index
            sequences: ["Ctrl+" + (index + 1), "Alt+" + (index + 1)]
            context: Qt.WindowShortcut
            onActivated: win.tabAt(index === 8 ? -1 : index)
        }
    }
    Shortcut {
        sequence: "Escape"
        context: Qt.WindowShortcut
        // Only for Flair Web's own layers: the page keeps Escape otherwise
        // (its dialogs, its fullscreen video).
        enabled: findBar.visible || (currentTab !== null && currentTab.readerOpen)
        onActivated: {
            if (findBar.visible) findBar.close()
            else if (currentTab && currentTab.readerOpen) currentTab.readerOpen = false
        }
    }

    // Tabs sleep after a while in the background.
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            const minutes = win.opt("tabs/sleepMinutes")
            if (minutes <= 0) return
            const limit = Date.now() - minutes * 60000
            for (const t of win.tabs)
                if (t !== win.currentTab && t.started && !t.audible && t.lastActive < limit) t.sleep()
        }
    }

    // ------------------------------------------------------------ layout
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        TabStrip {
            visible: !win.sideTabs && win.chromeVisible
            Layout.fillWidth: true
            win: win
        }

        // Toolbar.
        Rectangle {
            id: toolbar
            visible: win.chromeVisible || address.editing
            Layout.fillWidth: true
            Layout.preferredHeight: win.compactUi ? 40 : 48
            color: theme.sidebar
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 2
                IconButton {
                    visible: win.sideTabs
                    icon: "sidebar"
                    active: !win.opt("tabs/compact")
                    tip: "Onglets : complets ou compacts (Ctrl+B)"
                    onClicked: settings.set("tabs/compact", !win.opt("tabs/compact"))
                }
                IconButton { id: backButton; icon: "arrowLeft"; tip: "Précédente (Alt+←) · clic droit : l'historique de l'onglet"; enabledButton: win.currentTab !== null && win.currentTab.canGoBack; onClicked: win.currentTab.back()
                             onRightClicked: win.showHistoryMenu(backButton, true) }
                IconButton { id: forwardButton; icon: "arrowRight"; tip: "Suivante (Alt+→)"; enabledButton: win.currentTab !== null && win.currentTab.canGoForward; onClicked: win.currentTab.forward()
                             onRightClicked: win.showHistoryMenu(forwardButton, false) }
                IconButton {
                    icon: win.currentTab && win.currentTab.loading ? "stop" : "refresh"
                    tip: win.currentTab && win.currentTab.loading ? "Arrêter (Échap)" : "Recharger (F5) · clic droit : sans le cache"
                    enabledButton: win.currentTab !== null && win.currentTab.started
                    onClicked: win.currentTab.loading ? win.currentTab.stop() : win.currentTab.reload(false)
                    onRightClicked: win.currentTab.reload(true)
                }
                IconButton { visible: win.opt("toolbar/home"); icon: "home"; tip: "Accueil (Alt+Origine)"; onClicked: win.goHome() }
                Item { Layout.preferredWidth: 6 }
                AddressBar {
                    id: address
                    win: win
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: win.compactUi ? 30 : 34
                }
                Item { Layout.preferredWidth: 6 }
                Repeater {
                    id: extensionButtons
                    readonly property var hostWindow: win
                    model: win.opt("toolbar/extensionIcons") ? browser.extensions.filter(e => e.installed && e.enabled && e.hasAction) : []
                    delegate: ExtensionButton { required property var modelData; win: extensionButtons.hostWindow; info: modelData }
                }
                IconButton {
                    id: extensionsButton
                    visible: win.opt("toolbar/extensions") && browser.extensionsSupported
                    icon: "puzzle"; tip: "Extensions"
                    onClicked: extensionsPopup.showMenu(extensionsButton)
                }
                IconButton {
                    visible: win.opt("toolbar/downloads") && (appRoot.downloads.length > 0 || (library.downloadsRevision, library.downloads().length > 0))
                    icon: "download"
                    active: win.panelOpen && win.panelSection === "downloads"
                    tip: "Téléchargements (Ctrl+J)"
                    readonly property var live: appRoot ? appRoot.downloads.filter(d => d.totalBytes > 0 && !d.isFinished) : []
                    progress: live.length ? live.reduce((s, d) => s + d.receivedBytes, 0) / Math.max(1, live.reduce((s, d) => s + d.totalBytes, 0)) : -1
                    onClicked: win.showPanel("downloads", true)
                }
                IconButton {
                    visible: win.opt("toolbar/library")
                    icon: "bookmark"
                    active: win.panelOpen && (win.panelSection === "bookmarks" || win.panelSection === "history")
                    tip: "Favoris et historique (Ctrl+Maj+O, Ctrl+H)"
                    onClicked: win.showPanel(win.panelSection === "history" ? "history" : "bookmarks", true)
                }
                IconButton {
                    visible: win.opt("toolbar/ai")
                    icon: "sparkle"
                    active: win.panelOpen && win.panelSection === "assistant"
                    tip: "Assistant de page (Ctrl+Maj+A)"
                    onClicked: win.showPanel("assistant", true)
                }
                IconButton {
                    visible: win.opt("toolbar/devtools")
                    icon: "bug"; active: win.devtoolsOpen
                    tip: "Outils de développement (F12)"
                    onClicked: win.toggleDevtools()
                }
                IconButton {
                    visible: win.opt("toolbar/settings")
                    icon: "sliders"
                    tip: "Réglages (Ctrl+,)"
                    onClicked: win.openSettings()
                }
                IconButton { id: mainMenuButton; icon: "dots"; tip: "Menu"; onClicked: win.showMainMenu(mainMenuButton) }
            }
        }

        BookmarksBar {
            visible: win.bookmarksBarVisible
            Layout.fillWidth: true
            win: win
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            TabSidebar {
                id: tabSidebar
                visible: win.sideTabs && win.chromeVisible
                Layout.fillHeight: true
                // Never more than a third of a small window: the page keeps its room.
                Layout.preferredWidth: compact ? 56 : Math.round(Math.min(dragWidth > 0 ? dragWidth : win.opt("tabs/sideWidth"), Math.max(170, win.width * 0.3)))
                win: win
            }

            SplitView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                orientation: Qt.Vertical
                handle: Rectangle {
                    implicitHeight: 4
                    color: SplitHandle.hovered || SplitHandle.pressed ? theme.highlight : theme.line
                }

                // The page, in a card or edge to edge.
                Item {
                    SplitView.fillHeight: true
                    Rectangle {
                        id: card
                        anchors.fill: parent
                        anchors.margins: win.cardMargin
                        anchors.leftMargin: win.sideTabs && win.chromeVisible ? win.cardMargin * 0.5 : win.cardMargin
                        anchors.topMargin: win.bookmarksBarVisible ? win.cardMargin * 0.5 : (win.cardMargin > 0 ? 2 : 0)
                        radius: win.cardMargin > 0 ? win.opt("appearance/radius") : 0
                        color: theme.background
                        border.color: win.cardMargin > 0 ? theme.line : "transparent"
                        clip: true
                        // Every tab is created in here, fills it, and shows when current.
                        Item {
                            id: pageHost
                            anchors.fill: parent
                            anchors.margins: win.cardMargin > 0 ? 1 : 0
                        }

                        FindBar {
                            id: findBar
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 10
                            tab: win.currentTab
                            z: 10
                        }

                        // Where a link goes, on hover.
                        Rectangle {
                            visible: win.opt("toolbar/linkPreview") && win.currentTab !== null && win.currentTab.hoveredLink !== ""
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.margins: 6
                            width: Math.min(parent.width * 0.6, linkText.implicitWidth + 20)
                            height: 24
                            radius: 8
                            color: theme.surface
                            border.color: theme.line
                            z: 10
                            Text {
                                id: linkText
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                verticalAlignment: Text.AlignVCenter
                                text: win.currentTab ? win.currentTab.hoveredLink : ""
                                color: theme.textDim
                                font.pixelSize: 11
                                elide: Text.ElideMiddle
                            }
                        }

                        // Loading progress along the top edge.
                        Rectangle {
                            anchors.top: parent.top
                            height: 2
                            width: win.currentTab ? parent.width * win.currentTab.progress : 0
                            visible: win.currentTab !== null && win.currentTab.loading
                            color: theme.highlight
                            z: 10
                            Behavior on width { NumberAnimation { duration: 160 } }
                        }
                    }
                }

                // Developer tools for the current tab.
                Item {
                    visible: win.devtoolsOpen
                    SplitView.preferredHeight: win.height * 0.38
                    SplitView.minimumHeight: 120
                    Loader {
                        anchors.fill: parent
                        active: win.devtoolsOpen
                        sourceComponent: WebEngineView {
                            profile: win.currentTab && win.currentTab.isPrivate ? browser.privateProfile : browser.profile
                            inspectedView: win.currentTab ? win.currentTab.view : null
                        }
                    }
                }
            }

            SidePanel {
                id: sidePanel
                visible: win.panelOpen && win.chromeVisible
                Layout.fillHeight: true
                Layout.preferredWidth: Math.round(Math.min(380, Math.max(280, win.width * 0.3)))
                win: win
            }
        }
    }

    // Messages.
    Rectangle {
        id: toast
        property string text: ""
        function show(t) { text = t; opacity = 1; hide.restart() }
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 28
        width: Math.min(parent.width - 80, toastText.implicitWidth + 32)
        height: 36
        radius: 18
        color: theme.surface
        border.color: theme.line
        opacity: 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        Text { id: toastText; anchors.centerIn: parent; text: toast.text; color: theme.text; font.pixelSize: 13; elide: Text.ElideRight; width: Math.min(implicitWidth, parent.width - 32) }
        Timer { id: hide; interval: 3200; onTriggered: toast.opacity = 0 }
    }

    // Zen mode: a hint at the top.
    Rectangle {
        visible: win.zen && !win.pageFullScreen
        anchors.horizontalCenter: parent.horizontalCenter
        y: 6
        width: zenRow.implicitWidth + 20
        height: 26
        radius: 13
        color: theme.alpha(theme.surface, 0.9)
        border.color: theme.line
        opacity: zenHover.containsMouse ? 1 : 0.0
        Behavior on opacity { NumberAnimation { duration: 150 } }
        Row { id: zenRow; anchors.centerIn: parent; spacing: 8
            Icon { anchors.verticalCenter: parent.verticalCenter; name: "leaf"; size: 13; color: theme.highlight }
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Mode zen · Ctrl+Maj+F ou clic ici pour sortir"; color: theme.textDim; font.pixelSize: 11 } }
        MouseArea { id: zenHover; anchors.fill: parent; anchors.margins: -10; hoverEnabled: true; onClicked: win.zen = false }
    }

    function showHistoryMenu(anchor, backward) {
        const view = currentTab ? currentTab.view : null
        if (!view) return
        // Roles of WebEngineHistoryModel: url, title, offset (Qt.UserRole + 0…2).
        const model = backward ? view.history.backItems : view.history.forwardItems
        const entries = []
        for (let i = 0; i < model.rowCount(); ++i) {
            const index = model.index(i, 0)
            entries.push({ url: String(model.data(index, Qt.UserRole)), title: String(model.data(index, Qt.UserRole + 1) || ""),
                           offset: Number(model.data(index, Qt.UserRole + 2)) })
        }
        entries.sort((a, b) => Math.abs(a.offset) - Math.abs(b.offset))
        const list = entries.slice(0, 15).map(e => ({ text: e.title || e.url, icon: "clock",
                                                       run: () => view.goBackOrForward(e.offset) }))
        if (list.length) menu.showBelow(anchor, list, false)
    }

    FlairMenu { id: flairMenu }
    CommandPalette { id: palette; win: win }
    SettingsDialog { id: settingsDialog; win: win }
    ExtensionsPopup { id: extensionsPopup; win: win }
    BookmarkEditor { id: bookmarkEditor; win: win }

    Dialog {
        id: confirmClose
        property bool confirmed: false
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        width: 440
        title: "Fermer " + win.tabs.length + " onglets ?"
        background: Rectangle { color: theme.surface; radius: 14; border.color: theme.line }
        Text { width: parent.width; wrapMode: Text.Wrap; text: "Cette fenêtre et ses onglets se fermeront. Ctrl+Maj+T rouvre les onglets un par un."; color: theme.textDim }
        footer: DialogButtonBox {
            background: null
            Button { text: "Annuler"; flat: true; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
            PrimaryButton { text: "Fermer la fenêtre"; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }
        onAccepted: { confirmed = true; win.close(); confirmed = false }
    }

    Dialog {
        id: about
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        width: 440
        padding: 24
        background: Rectangle { color: theme.surface; radius: 16; border.color: theme.line }
        property bool isDefault: false
        onAboutToShow: isDefault = browser.isDefaultBrowser()
        ColumnLayout {
            anchors.fill: parent
            spacing: 14
            RowLayout {
                spacing: 16
                Logo { size: 56 }
                ColumnLayout {
                    spacing: 2
                    Text { text: "Flair Web"; color: theme.text; font.pixelSize: 26; font.weight: Font.Bold; font.letterSpacing: -0.6 }
                    Text { text: "Le navigateur de la suite flair · " + browser.version; color: theme.textDim; font.pixelSize: 13 }
                    Text { text: browser.engineVersion; color: theme.textFaint; font.pixelSize: 11 }
                }
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "Ton moteur de recherche, tes raccourcis, tes couleurs, tes scripts. Le bouclier bloque pubs et traceurs ; rien ne part ailleurs que vers les sites que tu visites."
                color: theme.textDim
                font.pixelSize: 12
                lineHeight: 1.2
            }
            RowLayout {
                spacing: 10
                PrimaryButton {
                    text: about.isDefault ? "Navigateur par défaut ✓" : "Définir par défaut"
                    enabled: !about.isDefault
                    onClicked: { about.isDefault = browser.makeDefaultBrowser(); win.flash(about.isDefault ? "Flair Web est le navigateur par défaut." : "Impossible : installe le paquet d'abord (bin/install).") }
                }
                Button { text: "Fermer"; flat: true; onClicked: about.close() }
            }
        }
    }

    Timer {
        id: devTimer
        interval: devInterval > 0 ? devInterval : 2500
        // Steps separated by " ;; ", one every 2.5 s.
        property var steps: devAction.split(" ;; ")
        property int step: 0
        repeat: true
        onTriggered: {
            const action = steps[step++] || ""
            if (step >= steps.length) stop()
            const what = action.split(":")[0]
            const arg = action.slice(what.length + 1)
            if (what === "settings") win.openSettings(arg)
            else if (what === "panel") win.showPanel(arg, false)
            else if (what === "palette") palette.show(arg || "")
            else if (what === "menu") win.showMainMenu(mainMenuButton)
            else if (what === "type") win.focusAddress(arg, "")
            else if (what === "reader") win.currentTab.readerOpen = true
            else if (what === "info") address.children[0]
            else if (what === "extensions") extensionsPopup.showMenu(extensionsButton)
            else if (what === "install") browser.installFromStore(arg)
            else if (what === "installdir") browser.installExtension(arg)
            else if (what === "contextmenu") { const items = appRoot.extensions.menuEntries(win, win.currentTab, { linkUrl: "", mediaUrl: "", selectedText: "", isContentEditable: false, mediaType: 0, frameUrl: "" }); console.log("MENU", JSON.stringify(items.map(i => i.text))); if (items.length) items[0].run() }
            else if (what === "popup") appRoot.extensions.actionClicked(browser.extensions.find(e => e.id === arg || e.name.toLowerCase().startsWith(arg)).id, win, null)
            else if (what === "open") { if (startupLog) browser.startupMark("dev: open " + arg); win.openTab(arg, {}) }
            else if (what === "js") win.currentTab.view.runJavaScript(arg, r => console.log("DEVJS", JSON.stringify(r)))
            else if (what === "jsfile") win.currentTab.view.runJavaScript(browser.readText(arg), r => console.log("DEVJS", JSON.stringify(r)))
            // Input as a user gives it: "click:x,y", "rclick", "mclick",
            // "double", "hover", "press", "release", "keys:text", "key:Ctrl+W".
            else if (["click", "rclick", "mclick", "double", "hover", "press", "release"].indexOf(what) >= 0) {
                const xy = arg.split(",").map(Number)
                const kind = what === "rclick" || what === "mclick" ? "click" : what === "hover" ? "move" : what
                browser.devMouse(win, kind, xy[0], xy[1], what === "rclick" ? 2 : what === "mclick" ? 4 : 1)
            }
            else if (what === "keys") browser.devType(win, arg)
            else if (what === "key") browser.devKey(win, arg)
            else if (what === "snap") console.log("DEVSNAP", arg, browser.devGrab(win, arg))
            else if (what === "resize") { const wh = arg.split(",").map(Number); win.width = wh[0]; win.height = wh[1] }
            else if (what === "state") console.log("DEVSTATE", JSON.stringify({
                tabs: win.tabs.map(t => t.title), current: win.tabs.indexOf(win.currentTab), width: win.width,
                addressFocus: address.editing, activeFocus: win.activeFocusItem ? String(win.activeFocusItem) : "",
                menuOpen: flairMenu.opened }))
        }
    }

    Component.onCompleted: {
        if (devAction !== "" && appRoot && appRoot.windows.length === 0) devTimer.start()
        if (appRoot && appRoot.windows.length > 1 && appRoot.lastActive && appRoot.lastActive !== win) {
            width = appRoot.lastActive.width
            height = appRoot.lastActive.height
        }
    }
}
