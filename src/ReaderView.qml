import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine

// Reading mode: the page's article, alone, set in a calm column with the
// font, size, width and colours chosen here.
Rectangle {
    id: reader
    property var owner: null
    property var article: null
    property string error: ""
    color: look.bg

    function opt(key) { return settings.revision, settings.value(key) }
    readonly property string themeKey: opt("reader/theme")
    readonly property var look: themeKey === "sepia" ? { bg: "#f4ecd8", fg: "#3b2f20", dim: "#7a6a55", link: "#9a5b13" }
        : themeKey === "light" ? { bg: "#fbfaf7", fg: "#1f1d1a", dim: "#6c675f", link: theme.readable(theme.highlight).toString() }
        : themeKey === "dark" ? { bg: "#151517", fg: "#e6e4df", dim: "#9a978f", link: theme.highlight.toString() }
        : { bg: theme.background.toString(), fg: theme.text.toString(), dim: theme.textDim.toString(), link: theme.highlight.toString() }

    // Finds the article like Readability does: the element whose
    // paragraphs hold the most text wins; link lists and chrome are dropped.
    readonly property string extractor: `(function () {
      // Every paragraph counts for all its ancestors; the article is the
      // deepest element that holds most of the page's paragraph text.
      var totals = new Map(), total = 0;
      document.querySelectorAll('p, pre, blockquote, li').forEach(function (p) {
        var len = (p.innerText || '').trim().length;
        if (len < 40) return;
        if (p.tagName === 'LI') len = len / 3;
        total += len;
        for (var el = p.parentElement; el && el !== document.documentElement; el = el.parentElement)
          totals.set(el, (totals.get(el) || 0) + len);
      });
      var best = null, bestDepth = -1;
      totals.forEach(function (v, el) {
        if (v < total * 0.7) return;
        var depth = 0;
        for (var e = el; e; e = e.parentElement) depth++;
        if (depth > bestDepth) { best = el; bestDepth = depth; }
      });
      var bestScore = best ? totals.get(best) : 0;
      if (best && best.closest('article')) best = best.closest('article');
      if (!best) best = document.querySelector('article, main') || document.body;
      var c = best.cloneNode(true);
      c.querySelectorAll('script, style, noscript, iframe, form, button, input, select, textarea, nav, aside, footer, header, svg, canvas, ' +
        '[aria-hidden=true], [role=navigation], [role=complementary], .ad, .ads, .advert, .share, .social, .related, .comments, .newsletter, ' +
        '.navbox, .infobox, .mw-editsection, .reference, .noprint, .metadata, sup.reference').forEach(function (n) { n.remove(); });
      c.querySelectorAll('ul, ol, div, table, section').forEach(function (n) {
        var text = (n.textContent || '').trim().length;
        if (!text) { if (!n.querySelector('img, video, figure, pre')) n.remove(); return; }
        var links = 0;
        n.querySelectorAll('a').forEach(function (a) { links += (a.textContent || '').length; });
        if (links / text > 0.6 && text < 4000) n.remove();
      });
      c.querySelectorAll('img').forEach(function (i) {
        var s = i.getAttribute('data-src') || i.getAttribute('src');
        if (s) { try { i.setAttribute('src', new URL(s, location.href).href); } catch (e) {} }
        ['srcset', 'sizes', 'width', 'height', 'loading', 'style'].forEach(function (a) { i.removeAttribute(a); });
      });
      c.querySelectorAll('a').forEach(function (a) {
        var h = a.getAttribute('href');
        if (h) { try { a.setAttribute('href', new URL(h, location.href).href); } catch (e) {} }
      });
      c.querySelectorAll('*').forEach(function (n) { n.removeAttribute('style'); n.removeAttribute('class'); n.removeAttribute('id'); });
      function meta(s) { var m = document.querySelector(s); return m ? m.getAttribute('content') || '' : ''; }
      var title = (document.querySelector('h1') || {}).innerText || meta('meta[property="og:title"]') || document.title;
      var first = c.querySelector('h1');
      if (first && title.indexOf((first.textContent || '').trim()) >= 0) first.remove();
      var text = c.textContent || '';
      return { title: title.trim(), site: meta('meta[property="og:site_name"]') || location.hostname.replace(/^www\\./, ''),
               byline: meta('meta[name="author"]'), html: c.innerHTML, words: text.split(/\\s+/).filter(Boolean).length };
    })()`

    function htmlEscape(s) { return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

    // Re-rendered only when the reader's own look changes, not on every
    // setting (the article would jump back to the top each time).
    property string renderedKey: ""
    function render(force) {
        if (!article) return
        const p = look
        const key = JSON.stringify([p, opt("reader/font"), opt("reader/size"), opt("reader/width"), theme.highlight.toString()])
        if (!force && key === renderedKey) return
        renderedKey = key
        const serif = opt("reader/font") === "serif"
        const family = serif ? "'Literata', 'Source Serif 4', 'Noto Serif', Georgia, serif"
                             : "'Inter', 'Noto Sans', system-ui, sans-serif"
        const minutes = Math.max(1, Math.round(article.words / 230))
        const css = "html{background:" + p.bg + ";}body{margin:0;padding:56px 24px 120px;color:" + p.fg + ";font-family:" + family +
            ";font-size:" + opt("reader/size") + "px;line-height:1.65;}main{max-width:" + opt("reader/width") + "px;margin:0 auto;}" +
            "h1.title{font-size:2em;line-height:1.2;margin:0 0 .4em;letter-spacing:-.01em;}" +
            ".meta{color:" + p.dim + ";font-family:'Inter',system-ui,sans-serif;font-size:.7em;letter-spacing:.02em;margin-bottom:2.4em;}" +
            "a{color:" + p.link + ";text-decoration-thickness:1px;text-underline-offset:2px;}" +
            "img,video,figure{max-width:100%;height:auto;border-radius:8px;}figure{margin:1.6em 0;}figcaption{color:" + p.dim + ";font-size:.8em;}" +
            "pre,code{font-family:'JetBrains Mono',monospace;font-size:.85em;}pre{overflow:auto;padding:1em;border-radius:8px;background:rgba(127,127,127,.12);}" +
            "blockquote{margin:1.4em 0;padding-left:1em;border-left:3px solid " + p.link + ";color:" + p.dim + ";}" +
            "h2,h3{line-height:1.3;margin-top:1.8em;}table{border-collapse:collapse;display:block;overflow-x:auto;max-width:100%;}body{overflow-x:hidden;}" +
            "td,th{border:1px solid rgba(127,127,127,.3);padding:.3em .6em;}" +
            "::selection{background:rgba(" + Math.round(theme.highlight.r * 255) + "," + Math.round(theme.highlight.g * 255) + "," + Math.round(theme.highlight.b * 255) + ",.35);}"
        const html = "<!doctype html><html><head><meta charset='utf-8'><style>" + css + "</style></head><body><main>" +
            "<h1 class='title'>" + htmlEscape(article.title) + "</h1><div class='meta'>" + htmlEscape(article.site) +
            (article.byline ? " · " + htmlEscape(article.byline) : "") + " · " + minutes + " min de lecture</div>" +
            article.html + "</main></body></html>"
        // loadHtml() stops at 2 MB; long articles go through a file in memory.
        if (html.length > 1500000) {
            const file = browser.writeRuntimeFile("reader-" + Date.now() % 100000 + ".html", html)
            if (file) { view.url = file; return }
        }
        view.loadHtml(html, owner ? owner.url : "")
    }

    function extract() {
        error = ""
        article = null
        if (!owner || !owner.view) { error = "Rien à lire ici."; return }
        owner.view.runJavaScript(extractor, (result) => {
            if (!result || !result.html || result.words < 60) {
                error = "Flair Web ne trouve pas d'article sur cette page."
                return
            }
            article = result
            render(true)
        })
    }

    Component.onCompleted: extract()
    onLookChanged: render()
    Connections {
        target: settings
        function onChanged() { reader.render() }
    }

    WebEngineView {
        id: view
        anchors.fill: parent
        anchors.topMargin: bar.height
        visible: reader.article !== null
        profile: reader.owner && reader.owner.isPrivate ? browser.privateProfile : browser.profile
        settings.javascriptEnabled: false
        settings.localContentCanAccessRemoteUrls: true
        backgroundColor: reader.look.bg
        // Links leave reading mode and open in the tab.
        onNavigationRequested: (request) => {
            if (request.navigationType === WebEngineNavigationRequest.LinkClickedNavigation) {
                request.reject()
                reader.owner.load(request.url.toString())
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: reader.error !== ""
        text: reader.error
        color: reader.look.dim
        font.pixelSize: 15
    }

    // Reading controls.
    Rectangle {
        id: bar
        width: parent.width
        height: 44
        color: reader.look.bg
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.alpha(reader.look.fg, 0.1) }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 10
            spacing: 6
            Icon { name: "book"; size: 16; color: theme.highlight }
            Text { visible: reader.width >= 460; text: "Lecture"; color: reader.look.fg; font.pixelSize: 13; font.weight: Font.DemiBold }
            Item { Layout.fillWidth: true }
            Repeater {
                model: [["serif", "Serif"], ["sans", "Sans"]]
                // A narrow page keeps the essentials (text size, close); the
                // rest comes back when the page is wider.
                delegate: Chip {
                    required property var modelData
                    visible: reader.width >= 720
                    text: modelData[1]
                    chosen: reader.opt("reader/font") === modelData[0]
                    onClicked: settings.set("reader/font", modelData[0])
                }
            }
            Rectangle { visible: reader.width >= 720; width: 1; height: 18; color: theme.alpha(reader.look.fg, 0.15) }
            IconButton { icon: "zoomOut"; tip: "Plus petit"; onClicked: settings.set("reader/size", Math.max(13, reader.opt("reader/size") - 1)) }
            Text { text: reader.opt("reader/size") + " px"; color: reader.look.dim; font.pixelSize: 12 }
            IconButton { icon: "zoomIn"; tip: "Plus grand"; onClicked: settings.set("reader/size", Math.min(32, reader.opt("reader/size") + 1)) }
            IconButton { visible: reader.width >= 720; icon: "shrink"; tip: "Colonne plus étroite"; onClicked: settings.set("reader/width", Math.max(460, reader.opt("reader/width") - 60)) }
            IconButton { visible: reader.width >= 720; icon: "expand"; tip: "Colonne plus large"; onClicked: settings.set("reader/width", Math.min(1200, reader.opt("reader/width") + 60)) }
            Rectangle { visible: reader.width >= 560; width: 1; height: 18; color: theme.alpha(reader.look.fg, 0.15) }
            Repeater {
                model: [["auto", "Flair", theme.background], ["light", "Clair", "#fbfaf7"], ["sepia", "Sépia", "#f4ecd8"], ["dark", "Sombre", "#151517"]]
                delegate: Rectangle {
                    required property var modelData
                    visible: reader.width >= 560
                    width: 22; height: 22; radius: 11
                    color: modelData[2]
                    border.width: reader.themeKey === modelData[0] ? 2 : 1
                    border.color: reader.themeKey === modelData[0] ? theme.highlight : theme.alpha(reader.look.fg, 0.25)
                    ToolTip.visible: themeHover.containsMouse
                    ToolTip.text: modelData[1]
                    MouseArea { id: themeHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: settings.set("reader/theme", modelData[0]) }
                }
            }
            Rectangle { width: 1; height: 18; color: theme.alpha(reader.look.fg, 0.15) }
            IconButton { icon: "close"; tip: "Quitter la lecture (Échap)"; onClicked: reader.owner.readerOpen = false }
        }
    }
}
