#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QtTest>
#include <QWebEngineUrlRequestInfo>
#include <QElapsedTimer>

#include "browser.h"
#include "dnr.h"
#include "engines.h"
#include "extensionhost.h"
#include "favicons.h"
#include "launcher.h"
#include "library.h"
#include "pageai.h"
#include "settings.h"
#include "shield.h"

static void write(const QString &path, const QByteArray &content) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(content);
}

class FlairWebTests : public QObject {
    Q_OBJECT

private slots:
    void setsAsideDuplicateExtensions() {
        QTemporaryDir dir;
        const auto install = dir.path() + "/Extensions", aside = dir.path() + "/aside";
        const QString id = "eiaeiblijfjekdanodkjadfinkhbfgcd";
        // An old copy never prepared, a prepared one, and a newer prepared one.
        write(install + "/" + id + "_old/manifest.json", "{}");
        write(install + "/" + id + "_mid/manifest.json", "{}");
        write(install + "/" + id + "_mid/flair/patch.json", "{}");
        QTest::qWait(1100);
        write(install + "/" + id + "_new/manifest.json", "{}");
        write(install + "/" + id + "_new/flair/patch.json", "{}");
        write(install + "/abcdefghijklmnopabcdefghijklmnop_x/manifest.json", "{}");
        QCOMPARE(Browser::setAsideDuplicateExtensions(install, aside), 2);
        QVERIFY(QFile::exists(install + "/" + id + "_new/manifest.json"));
        QVERIFY(!QFile::exists(install + "/" + id + "_old"));
        QVERIFY(!QFile::exists(install + "/" + id + "_mid"));
        QVERIFY(QFile::exists(install + "/abcdefghijklmnopabcdefghijklmnop_x/manifest.json"));
        QCOMPARE(QDir(aside).entryList(QDir::Dirs | QDir::NoDotAndDotDot).size(), 2);
        // Nothing left to do the second time.
        QCOMPARE(Browser::setAsideDuplicateExtensions(install, aside), 0);
    }
    void readsChromeThemeColours() {
        // A dark theme with a vivid link colour: dark mode, that accent.
        const auto dark = QJsonDocument::fromJson(R"({"colors": {"frame": [20, 22, 30], "toolbar": [32, 34, 44],
            "ntp_background": [18, 18, 24], "ntp_link": [80, 140, 255], "tab_text": [230, 230, 230]}})").object();
        auto c = Browser::chromeThemeColors(dark);
        QCOMPARE(c.value("mode").toString(), QString("dark"));
        QCOMPARE(c.value("accent").toString(), QColor(80, 140, 255).name());
        QCOMPARE(c.value("ntpColor").toString(), QColor(18, 18, 24).name());
        // A light theme in greys: light mode, no accent (the current one stays).
        const auto grey = QJsonDocument::fromJson(R"({"colors": {"frame": [222, 222, 222], "toolbar": [245, 245, 245],
            "ntp_background": [30, 30, 30]}})").object();
        c = Browser::chromeThemeColors(grey);
        QCOMPARE(c.value("mode").toString(), QString("light"));
        QVERIFY(!c.contains("accent"));
        // A new tab colour that would fight the mode is left out.
        QVERIFY(!c.contains("ntpColor"));
        // Malformed colours are ignored.
        QVERIFY(Browser::chromeThemeColors(QJsonDocument::fromJson(R"({"colors": {"frame": "red", "toolbar": [1]}})").object()).isEmpty());
    }
    void findsTheIconAPageDeclares() {
        const QUrl base("https://example.org/a/");
        // The icon closest to 64 px wins; SVG and touch icons only as a last resort.
        auto icon = Favicons::iconInPage(R"(<head><link rel="icon" href="/i16.png" sizes="16x16">
            <link rel="icon" type="image/png" href="i64.png" sizes="64x64"><link rel="icon" href="/logo.svg">
            <link rel="apple-touch-icon" href="/touch.png" sizes="180x180"></head>)", base);
        QCOMPARE(icon, QUrl("https://example.org/a/i64.png"));
        icon = Favicons::iconInPage(R"(<link href="/t.png" rel="apple-touch-icon">)", base);
        QCOMPARE(icon, QUrl("https://example.org/t.png"));
        // (A plain string: moc reads "//" in a raw string as a comment.)
        icon = Favicons::iconInPage("<link rel=\"shortcut icon\" href=\"/" "/cdn.example.org/f.ico?v=1&amp;x=2\">", base);
        QCOMPARE(icon, QUrl("https://cdn.example.org/f.ico?v=1&x=2"));
        QVERIFY(!Favicons::iconInPage("<link rel=stylesheet href=a.css>", base).isValid());
        QVERIFY(!Favicons::iconInPage("<link rel=\"icon\" href=\"javascript:void(0)\">", base).isValid());
    }
    void dnrMatchesFilters() {
        auto host = [](const QString &u) { const int s = u.indexOf("://") + 3; int e = s; while (e < u.size() && u[e] != '/' && u[e] != ':' && u[e] != '?') ++e; return QPair<int, int>(s, e); };
        auto m = [&](const QString &f, const QString &u) { const auto h = host(u); return Dnr::matchUrlFilter(f, u, h.first, h.second); };
        QVERIFY(m("||ads.example.com^", "https://ads.example.com/x.js"));
        QVERIFY(m("||example.com^", "https://cdn.ads.example.com/x"));
        QVERIFY(!m("||example.com^", "https://notexample.com/x"));
        QVERIFY(!m("||example.com^", "https://example.community/x"));
        QVERIFY(m("/ads/*.js|", "https://x.com/ads/a/b.js"));
        QVERIFY(!m("/ads/*.js|", "https://x.com/ads/a/b.json"));
        QVERIFY(m("|https://x.com/", "https://x.com/a"));
        QVERIFY(!m("|https://x.com/", "http://y.com/https://x.com/"));
        QVERIFY(m("banner^", "https://x.com/banner?x=1"));
        QVERIFY(m("banner^", "https://x.com/banner"));
        QVERIFY(!m("banner^", "https://x.com/banners"));
        QVERIFY(m("||pages.dev/*/alertmicrosoft.mp3", "https://evil.pages.dev/a/b/alertmicrosoft.mp3"));
    }
    void dnrAppliesRules() {
        QTemporaryDir dir;
        auto write = [&](const QString &name, const QByteArray &data) { QFile f(dir.path() + "/" + name); QVERIFY(f.open(QIODevice::WriteOnly)); f.write(data); };
        write("manifest.json", R"({"manifest_version": 3, "permissions": ["declarativeNetRequest"],
            "declarative_net_request": {"rule_resources": [{"id": "main", "enabled": true, "path": "rules.json"}, {"id": "off", "enabled": false, "path": "off.json"}]}})");
        write("rules.json", R"([
            {"id": 1, "action": {"type": "block"}, "condition": {"requestDomains": ["doubleclick.net", "tracker.io"]}},
            {"id": 2, "action": {"type": "block"}, "condition": {"urlFilter": "/pixel.gif", "resourceTypes": ["image"]}},
            {"id": 3, "priority": 2, "action": {"type": "allow"}, "condition": {"urlFilter": "||tracker.io/ok^", "initiatorDomains": ["good.com"]}},
            {"id": 4, "action": {"type": "block"}, "condition": {"urlFilter": "||cdn.com/ad.js", "domainType": "thirdParty"}},
            {"id": 5, "action": {"type": "redirect", "redirect": {"extensionPath": "/noop.js"}}, "condition": {"urlFilter": "||ads.com/lib.js"}},
            {"id": 6, "action": {"type": "allowAllRequests"}, "condition": {"requestDomains": ["trusted.org"], "resourceTypes": ["main_frame"]}}
        ])");
        write("off.json", R"([{"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "everything"}}])");
        Dnr dnr(dir.path() + "/state");
        dnr.setExtension("abc", dir.path());
        const int script = QWebEngineUrlRequestInfo::ResourceTypeScript;
        const int image = QWebEngineUrlRequestInfo::ResourceTypeImage;
        const int main = QWebEngineUrlRequestInfo::ResourceTypeMainFrame;
        auto eval = [&](const QString &url, const QString &from, int type) {
            return dnr.evaluate(QUrl(url), QUrl(from), QUrl(from), type, "GET");
        };
        QVERIFY(eval("https://securepubads.g.doubleclick.net/tag.js", "https://news.com/", script).block);
        QVERIFY(!eval("https://news.com/app.js", "https://news.com/", script).block);
        QVERIFY(eval("https://x.com/a/pixel.gif?u=1", "https://news.com/", image).block);
        QVERIFY(!eval("https://x.com/a/pixel.gif?u=1", "https://news.com/", script).block);
        QVERIFY(eval("https://tracker.io/ok/x", "https://news.com/", script).block);
        QVERIFY(!eval("https://tracker.io/ok/x", "https://good.com/", script).block);
        QVERIFY(eval("https://cdn.com/ad.js", "https://news.com/", script).block);
        QVERIFY(!eval("https://cdn.com/ad.js", "https://www.cdn.com/", script).block);
        QCOMPARE(eval("https://ads.com/lib.js", "https://news.com/", script).redirect, QUrl("chrome-extension://abc/noop.js"));
        QVERIFY(!eval("https://everything.com/", "https://news.com/", script).block);
        // A trusted page: its requests are all allowed.
        eval("https://trusted.org/", "", main);
        QVERIFY(!eval("https://doubleclick.net/x", "https://trusted.org/", script).block);
        // The extension's API.
        QString error;
        dnr.call("abc", "updateDynamicRules", {QVariantMap{{"addRules", QVariantList{QVariantMap{
            {"id", 7}, {"action", QVariantMap{{"type", "block"}}}, {"condition", QVariantMap{{"urlFilter", "||news.com/app.js"}}}}}}}}, &error);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QVERIFY(eval("https://news.com/app.js", "https://news.com/", script).block);
        QCOMPARE(dnr.call("abc", "getDynamicRules", {}, &error).toList().size(), 1);
        dnr.call("abc", "updateEnabledRulesets", {QVariantMap{{"disableRulesetIds", QVariantList{"main"}}}}, &error);
        QVERIFY(!eval("https://securepubads.g.doubleclick.net/tag.js", "https://news.com/", script).block);
        QCOMPARE(dnr.call("abc", "getEnabledRulesets", {}, &error).toStringList(), QStringList());
        // Dynamic rules survive a restart.
        Dnr again(dir.path() + "/state");
        again.setExtension("abc", dir.path());
        QVERIFY(again.evaluate(QUrl("https://news.com/app.js"), QUrl("https://news.com/"), QUrl("https://news.com/"), script, "GET").block);
        // uBlock Origin Lite's real rules, when available.
        const auto ubol = qEnvironmentVariable("FLAIRWEB_UBOL_DIR");
        if (!ubol.isEmpty()) {
            Dnr real(dir.path() + "/real");
            real.setExtension("ubol", ubol);
            qInfo() << "uBOL rules:" << real.ruleCount();
            QElapsedTimer timer; timer.start();
            int blocked = 0;
            const QStringList ads = {"https://securepubads.g.doubleclick.net/tag/js/gpt.js", "https://www.googletagmanager.com/gtm.js?id=GTM-X",
                                     "https://www.google-analytics.com/analytics.js", "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
                                     "https://static.criteo.net/js/ld/publishertag.js", "https://c.amazon-adsystem.com/aax2/apstag.js",
                                     "https://connect.facebook.net/en_US/fbevents.js", "https://cdn.taboola.com/libtrc/site/loader.js",
                                     "https://widgets.outbrain.com/outbrain.js", "https://sb.scorecardresearch.com/beacon.js",
                                     "https://script.hotjar.com/modules.js", "https://ib.adnxs.com/ut/v3/prebid"};
            for (const auto &u : ads) {
                const auto o = real.evaluate(QUrl(u), QUrl("https://news.example/"), QUrl("https://news.example/"), script, "GET");
                const bool b = o.block || o.redirect.isValid();
                if (!b) qInfo() << "not blocked:" << u;
                else if (o.redirect.isValid()) qInfo() << "neutered:" << u << "->" << o.redirect.toString();
                blocked += b;
            }
            const QStringList fine = {"https://news.example/app.js", "https://cdn.jsdelivr.net/npm/vue@3/dist/vue.js", "https://fonts.googleapis.com/css2?family=Inter",
                                      "https://code.jquery.com/jquery-3.7.1.min.js", "https://upload.wikimedia.org/x.png"};
            for (const auto &u : fine)
                QVERIFY2(!real.evaluate(QUrl(u), QUrl("https://news.example/"), QUrl("https://news.example/"), script, "GET").block, qPrintable(u));
            qInfo() << "blocked" << blocked << "of" << ads.size() << "in" << timer.elapsed() << "ms";
            QVERIFY(blocked >= ads.size() - 2);
        }
    }
    void injectsTheBridgeInPages() {
        const auto out = ExtensionHost::injectScripts("<!DOCTYPE html>\n<html id=\"x\">\n<head>\n<meta charset=\"utf-8\">");
        QVERIFY(out.contains("<head><script src=\"/flair/config.js\"></script><script src=\"/flair/messages.js\"></script><script src=\"/flair/bridge.js\"></script>"));
        QCOMPARE(ExtensionHost::injectScripts(out), out);
        QVERIFY(ExtensionHost::injectScripts("<p>hi</p>").startsWith("<script src=\"/flair/config.js\">"));
    }
    void patchesExtensionCsp() {
        QCOMPARE(ExtensionHost::patchCsp("script-src 'self'; connect-src 'self' https://a.com"),
                 QString("script-src 'self'; connect-src 'self' https://a.com http://127.0.0.1:* ws://127.0.0.1:*"));
        QCOMPARE(ExtensionHost::patchCsp("default-src 'none'; script-src 'self'"),
                 QString("default-src 'none'; script-src 'self'; connect-src http://127.0.0.1:* ws://127.0.0.1:*"));
        QCOMPARE(ExtensionHost::patchCsp("script-src 'self'"), QString("script-src 'self'"));
    }
    void patchesAnExtensionFolder() {
        QTemporaryDir dir;
        QDir().mkpath(dir.path() + "/js");
        auto write = [&](const QString &name, const QByteArray &data) { QFile f(dir.path() + "/" + name); QVERIFY(f.open(QIODevice::WriteOnly)); f.write(data); };
        write("manifest.json", R"({"manifest_version": 3, "name": "t", "version": "1", "background": {"service_worker": "js/bg.js", "type": "module"},
                                   "content_scripts": [{"matches": ["<all_urls>"], "js": ["js/cs.js"]}]})");
        write("popup.html", "<!doctype html><html><head><title>p</title></head><body></body></html>");
        write("js/page.html", "<html><body>x</body></html>");
        Dnr dnr(dir.path() + "/dnr");
        ExtensionHost host(&dnr, dir.path());
        QString error;
        QVERIFY2(host.patch(dir.path(), &error), qPrintable(error));
        QFile popup(dir.path() + "/popup.html");
        QVERIFY(popup.open(QIODevice::ReadOnly));
        QVERIFY(popup.readAll().contains("/flair/bridge.js"));
        QFile page(dir.path() + "/js/page.html");
        QVERIFY(page.open(QIODevice::ReadOnly));
        QVERIFY(page.readAll().contains("/flair/bridge.js"));
        QFile manifest(dir.path() + "/manifest.json");
        QVERIFY(manifest.open(QIODevice::ReadOnly));
        const auto m = QJsonDocument::fromJson(manifest.readAll()).object();
        QCOMPARE(m.value("background").toObject().value("service_worker").toString(), QString("js/flair-worker.js"));
        QCOMPARE(m.value("content_scripts").toArray().size(), 2);
        QFile worker(dir.path() + "/js/flair-worker.js");
        QVERIFY(worker.open(QIODevice::ReadOnly));
        QVERIFY(worker.readAll().contains("import \"/js/bg.js\""));
    }
    void storeExtensionIds() {
        const QString id = "ddkjiahejlhfcafbddmgiahcphecmpfh";
        QCOMPARE(Browser::extensionIdIn(id), id);
        QCOMPARE(Browser::extensionIdIn("https://chromewebstore.google.com/detail/ublock-origin-lite/" + id), id);
        QCOMPARE(Browser::extensionIdIn("https://chromewebstore.google.com/detail/ublock-origin-lite/" + id + "?hl=fr"), id);
        QCOMPARE(Browser::extensionIdIn("https://chrome.google.com/webstore/detail/x/" + id), id);
        QCOMPARE(Browser::extensionIdIn("https://chromewebstore.google.com/"), QString());
        QCOMPARE(Browser::extensionIdIn("ddkjiahejlhfcafbddmgiahcphecmpfz"), QString()); // z is not an id letter
    }
    void crxUnwrapsToZip() {
        const QByteArray zip = QByteArray("PK\x03\x04", 4) + "rest of the archive";
        QCOMPARE(Browser::crxToZip(zip), zip);
        auto le = [](quint32 v) { QByteArray b(4, 0); qToLittleEndian(v, b.data()); return b; };
        const QByteArray crx3 = "Cr24" + le(3) + le(5) + "HEADR" + zip;
        QCOMPARE(Browser::crxToZip(crx3), zip);
        const QByteArray crx2 = "Cr24" + le(2) + le(3) + le(2) + "KEY" + "SG" + zip;
        QCOMPARE(Browser::crxToZip(crx2), zip);
        QVERIFY(Browser::crxToZip("Cr24" + le(3) + le(500) + zip).isEmpty());   // header past the end
        QVERIFY(Browser::crxToZip("<html>not an extension</html>").isEmpty());
    }
    // ------------------------------------------------------------ addresses
    void tellsAddressesFromSearches() {
        for (const auto &url : {"example.com", "https://x", "http://localhost", "localhost:3000", "localhost:3000/api",
                                "192.168.1.1/admin", "10.0.0.2:8080", "fr.wikipedia.org/wiki/Navigateur_web",
                                "~/page.html", "/tmp/a.html", "about:blank", "sub.domain.co.uk", "xn--bcher-kva.de",
                                "file:///etc/hosts", "view-source:https://a.fr", "[::1]:8000", "café.fr", "user@example.com"})
            QVERIFY2(SearchEngines::looksLikeUrl(url), url);
        for (const auto &query : {"", "hello world", "navigateur web", "c++", "3.14", "e.g", "what is a.b c",
                                  "comment faire ?", "rust vs go", "flair"})
            QVERIFY2(!SearchEngines::looksLikeUrl(query), query);
    }

    void completesAddresses() {
        QCOMPARE(SearchEngines::normalizeUrl("example.com"), QString("https://example.com"));
        QCOMPARE(SearchEngines::normalizeUrl("  example.com/a?b=1 "), QString("https://example.com/a?b=1"));
        QCOMPARE(SearchEngines::normalizeUrl("localhost:8080"), QString("http://localhost:8080"));
        QCOMPARE(SearchEngines::normalizeUrl("192.168.0.1"), QString("http://192.168.0.1"));
        QCOMPARE(SearchEngines::normalizeUrl("http://x.org"), QString("http://x.org"));
        QCOMPARE(SearchEngines::normalizeUrl("about:blank"), QString("about:blank"));
        QCOMPARE(SearchEngines::normalizeUrl("/tmp/a b.html"), QString("file:///tmp/a%20b.html"));
        QCOMPARE(SearchEngines::normalizeUrl("~/x.html"), QUrl::fromLocalFile(QDir::homePath() + "/x.html").toString(QUrl::FullyEncoded));
    }

    void resolvesSearchesAndKeywords() {
        QTemporaryDir dir;
        BrowserSettings settings(dir.path() + "/s.conf");
        SearchEngines engines(&settings);

        auto r = engines.resolve("hello world", "duckduckgo");
        QCOMPARE(r.value("kind").toString(), QString("search"));
        QCOMPARE(r.value("url").toString(), QString("https://duckduckgo.com/?q=hello%20world"));

        r = engines.resolve("yt chats mignons", "duckduckgo");
        QCOMPARE(r.value("engine").toString(), QString("youtube"));
        QCOMPARE(r.value("url").toString(), QString("https://www.youtube.com/results?search_query=chats%20mignons"));

        r = engines.resolve("!wiki Lyon", "google");
        QCOMPARE(r.value("engine").toString(), QString("wikipedia"));
        QVERIFY(r.value("url").toString().endsWith("search=Lyon"));

        r = engines.resolve("Lyon !wiki", "google");
        QCOMPARE(r.value("engine").toString(), QString("wikipedia"));

        // A keyword alone opens the engine's home page.
        r = engines.resolve("gh ", "google");
        QCOMPARE(r.value("url").toString(), QString("https://github.com/"));

        // Unknown words stay searches; addresses stay addresses.
        QCOMPARE(engines.resolve("zz top", "google").value("engine").toString(), QString("google"));
        QCOMPARE(engines.resolve("example.com", "google").value("url").toString(), QString("https://example.com"));

        // Encoding.
        QCOMPARE(engines.searchUrl("google", "a b&c=d"), QString("https://www.google.com/search?q=a%20b%26c%3Dd"));
        // Unknown engine keys fall back to the first engine.
        QCOMPARE(engines.engine("nope").value("key").toString(), QString("duckduckgo"));

        // "bang" mode: only !kw triggers; "off": nothing.
        settings.set("search/keywords", "bang");
        QCOMPARE(engines.resolve("yt chats", "google").value("engine").toString(), QString("google"));
        QCOMPARE(engines.resolve("!yt chats", "google").value("engine").toString(), QString("youtube"));
        settings.set("search/keywords", "off");
        QCOMPARE(engines.resolve("!yt chats", "google").value("engine").toString(), QString("google"));
    }

    void editsEngines() {
        QTemporaryDir dir;
        BrowserSettings settings(dir.path() + "/s.conf");
        SearchEngines engines(&settings);
        const int builtins = engines.all().size();

        const auto key = engines.addCustom("Mon wiki", "mw", "https://wiki.local/?s=%s", "");
        QVERIFY(!key.isEmpty());
        QCOMPARE(engines.all().size(), builtins + 1);
        QCOMPARE(engines.resolve("mw test", "google").value("url").toString(), QString("https://wiki.local/?s=test"));
        QVERIFY(engines.addCustom("", "x", "https://a/%s").isEmpty());

        engines.updateEngine(key, "Wiki maison", "wm", "https://wiki.local/find?q=%s", "");
        QCOMPARE(engines.engine(key).value("name").toString(), QString("Wiki maison"));
        QCOMPARE(engines.resolve("wm a", "google").value("url").toString(), QString("https://wiki.local/find?q=a"));

        // A built-in keeps only what changed, and can be reset.
        engines.updateEngine("youtube", "YouTube", "tube", "https://www.youtube.com/results?search_query=%s",
                             engines.engine("youtube").value("suggest").toString());
        QCOMPARE(engines.engine("youtube").value("keyword").toString(), QString("tube"));
        QVERIFY(engines.engine("youtube").value("custom").toBool());
        const auto overrides = QJsonDocument::fromJson(settings.value("search/overrides").toString().toUtf8()).object();
        QCOMPARE(overrides.value("youtube").toObject().keys(), QStringList{"keyword"});
        engines.resetBuiltin("youtube");
        QCOMPARE(engines.engine("youtube").value("keyword").toString(), QString("yt"));

        engines.setHidden("bing", true);
        QCOMPARE(engines.all().size(), builtins); // custom + one hidden
        QCOMPARE(engines.all(true).size(), builtins + 1);
        engines.setHidden("bing", false);

        engines.removeCustom(key);
        QCOMPARE(engines.all().size(), builtins);
    }

    void parsesSuggestions() {
        QCOMPARE(SearchEngines::parseSuggestions(R"(["chat", ["chat noir", "chatgpt", "chat noir"]])"),
                 (QStringList{"chat noir", "chatgpt"}));
        QCOMPARE(SearchEngines::parseSuggestions(R"([{"phrase": "a"}, {"phrase": "b"}])"), (QStringList{"a", "b"}));
        QCOMPARE(SearchEngines::parseSuggestions(R"({"status":"success","data":{"items":[{"value":"q1"},{"value":"q2"}]}})"),
                 (QStringList{"q1", "q2"}));
        QVERIFY(SearchEngines::parseSuggestions("not json").isEmpty());
    }

    // ------------------------------------------------------------ settings
    void settingsKeepTypesAndDefaults() {
        QTemporaryDir dir;
        BrowserSettings settings(dir.path() + "/s.conf");
        QCOMPARE(settings.value("privacy/shield").typeId(), QMetaType::Bool);
        QCOMPARE(settings.value("tabs/sideWidth").toInt(), 248);
        settings.set("tabs/sideWidth", 300);
        settings.set("privacy/shield", false);
        settings.set("web/zoom", 1.25);

        BrowserSettings again(dir.path() + "/s.conf");
        QCOMPARE(again.value("tabs/sideWidth").toInt(), 300);
        QCOMPARE(again.value("privacy/shield").toBool(), false);
        QCOMPARE(again.value("privacy/shield").typeId(), QMetaType::Bool);
        QCOMPARE(again.value("web/zoom").toDouble(), 1.25);
        // Setting the default removes the key.
        again.set("tabs/sideWidth", 248);
        QVERIFY(!again.isCustom("tabs/sideWidth"));
        QCOMPARE(QFile(dir.path() + "/s.conf").permissions() & (QFileDevice::ReadGroup | QFileDevice::ReadOther), QFileDevice::Permissions());

        QVERIFY(BrowserSettings::userAgentFor("firefox", "").contains("Firefox/"));
        QVERIFY(BrowserSettings::userAgentFor("mobile", "").contains("Mobile"));
        QCOMPARE(BrowserSettings::userAgentFor("custom", "  Moi/1.0 "), QString("Moi/1.0"));
        QVERIFY(BrowserSettings::userAgentFor("default", "x").isEmpty());
        settings.set("downloads/dir", "~/Truc");
        QCOMPARE(settings.downloadDirectory(), QDir::homePath() + "/Truc");
    }

    // ------------------------------------------------------------ library
    void remembersHistory() {
        QTemporaryDir dir;
        Library library(dir.path());
        library.visit("https://www.example.com/", "Example");
        library.visit("https://www.example.com/", "Example"); // within 5 s: not counted twice
        library.visit("https://example.com/docs/page", "Docs");
        library.visit("https://other.org/", "Autre");
        library.visit("about:blank", "");
        library.visit("data:text/html,x", "");
        QCOMPARE(library.historyCount(), 3);
        QCOMPARE(library.history("", 10).first().toMap().value("url").toString(), QString("https://other.org/"));
        QCOMPARE(library.history("docs", 10).size(), 1);
        QCOMPARE(library.history("EXAMPLE", 10).size(), 2);

        // The site typed first ranks first, its home page before deep links.
        const auto s = library.suggest("exa", 5);
        QCOMPARE(s.size(), 2);
        QCOMPARE(s.first().toMap().value("url").toString(), QString("https://www.example.com/"));
        QCOMPARE(library.suggest("éxa", 5).size(), 2); // accents are ignored

        const auto top = library.topSites(5);
        QCOMPARE(top.size(), 2);
        QCOMPARE(top.first().toMap().value("host").toString(), QString("example.com"));

        library.updateTitle("https://other.org/", "Autre site");
        QCOMPARE(library.history("site", 5).size(), 1);
        library.removeHistory("https://other.org/");
        QCOMPARE(library.historyCount(), 2);
        library.flush();

        Library again(dir.path());
        QCOMPARE(again.historyCount(), 2);
        again.clearHistory(QDateTime::currentMSecsSinceEpoch() + 1000.0);
        QCOMPARE(again.historyCount(), 2); // nothing visited after the future
        again.clearHistory(0);
        QCOMPARE(again.historyCount(), 0);
    }

    void keepsBookmarks() {
        QTemporaryDir dir;
        Library library(dir.path());
        QVERIFY(library.toggleBookmark("https://a.fr/", "A"));
        library.addBookmark("https://b.fr/", "B", "Lecture");
        library.addBookmark("https://a.fr/", "Doublon");
        QCOMPARE(library.bookmarks().size(), 2);
        QVERIFY(library.isBookmarked("https://a.fr/"));
        QCOMPARE(library.folders(), QStringList{"Lecture"});
        library.editBookmark("https://a.fr/", "A !", "https://a.fr/x", "Outils");
        QVERIFY(!library.isBookmarked("https://a.fr/"));
        QCOMPARE(library.bookmark("https://a.fr/x").value("folder").toString(), QString("Outils"));
        library.moveBookmark(1, 0);
        QCOMPARE(library.bookmarks().first().toMap().value("url").toString(), QString("https://b.fr/"));
        QVERIFY(!library.toggleBookmark("https://b.fr/", "B"));
        QCOMPARE(library.bookmarks().size(), 1);
    }

    void importsAndExportsBookmarks() {
        QTemporaryDir dir;
        Library library(dir.path() + "/lib");
        // Chromium's JSON.
        const QJsonObject chromium{{"roots", QJsonObject{
            {"bookmark_bar", QJsonObject{{"children", QJsonArray{
                QJsonObject{{"type", "url"}, {"name", "Rust"}, {"url", "https://rust-lang.org/"}},
                QJsonObject{{"type", "folder"}, {"name", "Dev"}, {"children", QJsonArray{
                    QJsonObject{{"type", "url"}, {"name", "Qt"}, {"url", "https://qt.io/"}}}}}}}}},
            {"other", QJsonObject{{"children", QJsonArray{
                QJsonObject{{"type", "url"}, {"name", "Arch"}, {"url", "https://archlinux.org/"}}}}}}}}};
        write(dir.path() + "/Bookmarks", QJsonDocument(chromium).toJson());
        QCOMPARE(library.importBookmarks(dir.path() + "/Bookmarks"), 3);
        QCOMPARE(library.importBookmarks(dir.path() + "/Bookmarks"), 0); // no duplicates
        QCOMPARE(library.bookmark("https://qt.io/").value("folder").toString(), QString("Dev"));
        QCOMPARE(library.bookmark("https://rust-lang.org/").value("folder").toString(), QString());
        QCOMPARE(library.bookmark("https://archlinux.org/").value("folder").toString(), QString("Autres favoris"));

        // Netscape HTML, as Firefox writes it.
        write(dir.path() + "/ff.html", R"(<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
    <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Barre personnelle</H3>
    <DL><p>
        <DT><A HREF="https://lemonde.fr/" ADD_DATE="1">Le Monde &amp; co</A>
    </DL><p>
    <DT><H3>Recettes</H3>
    <DL><p>
        <DT><A HREF="https://marmiton.org/">Marmiton</A>
        <DT><A HREF="place:sort=8">Récents</A>
    </DL><p>
</DL>)");
        QCOMPARE(library.importBookmarks("file://" + dir.path() + "/ff.html"), 2);
        QCOMPARE(library.bookmark("https://lemonde.fr/").value("title").toString(), QString("Le Monde & co"));
        QCOMPARE(library.bookmark("https://lemonde.fr/").value("folder").toString(), QString());
        QCOMPARE(library.bookmark("https://marmiton.org/").value("folder").toString(), QString("Recettes"));
        QCOMPARE(library.importBookmarks(dir.path() + "/missing.html"), -1);

        // Export, then import elsewhere: the same set comes back.
        QVERIFY(library.exportBookmarks(dir.path() + "/out.html"));
        Library other(dir.path() + "/other");
        QCOMPARE(other.importBookmarks(dir.path() + "/out.html"), library.bookmarks().size());
        QCOMPARE(other.bookmark("https://marmiton.org/").value("folder").toString(), QString("Recettes"));
    }

    void keepsShortcutsZoomSessionAndDownloads() {
        QTemporaryDir dir;
        {
            Library library(dir.path());
            const int seeds = library.dial().size();
            QVERIFY(seeds > 0);
            library.addDial("https://kagi.com/", "");
            QCOMPARE(library.dial().last().toMap().value("title").toString(), QString("kagi.com"));
            library.moveDial(seeds, 0);
            QCOMPARE(library.dial().first().toMap().value("url").toString(), QString("https://kagi.com/"));
            library.removeDial(0);
            QCOMPARE(library.dial().size(), seeds);
            QVERIFY(!library.inDial("https://kagi.com/"));

            library.setZoom("https://www.youtube.com/watch?v=1", 1.25);
            QCOMPARE(library.zoomFor("https://youtube.com/"), 1.25);
            library.setZoom("https://youtube.com/", 0);
            QCOMPARE(library.zoomFor("https://youtube.com/"), 0.0);
            library.setZoom("https://a.fr/", 0.8);

            library.saveSession({QVariantMap{{"tabs", QVariantList{QVariantMap{{"url", "https://a.fr/"}, {"title", "A"}, {"pinned", true}}}}, {"current", 0}}});
            library.logDownload({{"name", "f.zip"}, {"path", dir.path() + "/f.zip"}, {"url", "https://a.fr/f.zip"}, {"size", 10}, {"ok", true}});
            library.logDownload({{"name", "f.zip"}, {"path", dir.path() + "/f.zip"}, {"url", "https://a.fr/f.zip"}, {"size", 12}, {"ok", true}});
            QCOMPARE(library.downloads().size(), 1);
            QCOMPARE(library.downloads().first().toMap().value("exists").toBool(), false);
        }
        Library again(dir.path());
        QCOMPARE(again.zoomFor("https://a.fr/page"), 0.8);
        const auto session = again.session();
        QCOMPARE(session.size(), 1);
        QCOMPARE(session.first().toMap().value("tabs").toList().first().toMap().value("pinned").toBool(), true);
        QCOMPARE(again.downloads().first().toMap().value("size").toInt(), 12);
        again.removeDownload(dir.path() + "/f.zip");
        QVERIFY(again.downloads().isEmpty());
        QCOMPARE(Library::fold("Éléphant Ça"), QString("elephant ca"));
        QCOMPARE(Library::hostOf("https://WWW.Example.com:8080/a"), QString("example.com"));
    }

    // ------------------------------------------------------------ shield
    void parsesBlockLists() {
        const auto domains = Shield::parseHostsFile("# comment\n0.0.0.0 ads.example.com\n127.0.0.1 localhost\n"
                                                    "0.0.0.0 tracker.net # trailing\n||adblock.style^\n! adblock comment\n"
                                                    "plain-domain.org\n0.0.0.0 0.0.0.0\n::1 ip6-localhost\n*.wild.com\n");
        QCOMPARE(domains, (QStringList{"ads.example.com", "tracker.net", "adblock.style", "plain-domain.org"}));
    }

    void blocksTrackersButNotTheSite() {
        QTemporaryDir dir;
        BrowserSettings settings(dir.path() + "/s.conf");
        settings.set("privacy/lists", "none");
        settings.set("privacy/blocked", "evil.example\n# comment\n");
        Shield shield(&settings, dir.path() + "/shield");
        QVERIFY(shield.shouldBlock("www.google-analytics.com", "lemonde.fr"));
        QVERIFY(shield.shouldBlock("securepubads.g.doubleclick.net", "youtube.com"));
        QVERIFY(shield.shouldBlock("cdn.evil.example", "site.fr"));
        QVERIFY(!shield.shouldBlock("static.lemonde.fr", "lemonde.fr"));
        QVERIFY(!shield.shouldBlock("fonts.gstatic.com", "lemonde.fr"));
        // A listed site visited directly is its own first party.
        QVERIFY(!shield.shouldBlock("taboola.com", "taboola.com"));
        QVERIFY(!shield.shouldBlock("", "a.fr"));

        QVERIFY(!shield.isAllowed("https://www.lemonde.fr/"));
        shield.setAllowed("https://www.lemonde.fr/article", true);
        QVERIFY(shield.isAllowed("https://lemonde.fr/"));
        QCOMPARE(settings.value("privacy/allowed").toString(), QString("lemonde.fr"));
        shield.setAllowed("https://lemonde.fr/", false);
        QVERIFY(!shield.isAllowed("https://lemonde.fr/"));

        QVERIFY(Shield::isPrivateHost("localhost"));
        QVERIFY(Shield::isPrivateHost("192.168.1.20"));
        QVERIFY(Shield::isPrivateHost("nas.local"));
        QVERIFY(!Shield::isPrivateHost("example.com"));
        QVERIFY(!Shield::isPrivateHost("8.8.8.8"));

        const auto lists = shield.lists();
        QVERIFY(lists.size() >= 3);
        for (const auto &l : lists)
            QVERIFY(!l.toMap().value("enabled").toBool()); // "none"
    }

    // ------------------------------------------------------------ page styles and scripts
    void matchesSitePatterns() {
        QVERIFY(Browser::sitePatternMatches("youtube.com", "www.youtube.com"));
        QVERIFY(Browser::sitePatternMatches("youtube.com", "music.youtube.com"));
        QVERIFY(!Browser::sitePatternMatches("youtube.com", "notyoutube.com"));
        QVERIFY(Browser::sitePatternMatches("*.wiki*", "fr.wikipedia.org"));
        QVERIFY(Browser::sitePatternMatches("*", "anything.net"));
        QVERIFY(!Browser::sitePatternMatches("", "a.fr"));
    }

    void buildsPageScripts() {
        QVERIFY(Browser::styleScript("", "[]", "", {}).isEmpty());
        QVERIFY(Browser::userScript("  ", "[]").isEmpty());

        const QString sites = R"json([{"pattern":"youtube.com","css":"#secondary{display:none}","js":"document.title='x'","enabled":true},
                                  {"pattern":"off.fr","css":"a{}","js":"alert(1)","enabled":false}])json";
        const auto style = Browser::styleScript("body { font-family: \"Inter\" } </script>", sites, ".ad{display:none}", {"lemonde.fr"});
        QVERIFY(style.contains("#secondary{display:none}"));
        QVERIFY(!style.contains("off.fr"));
        QVERIFY(style.contains(R"(body { font-family: \"Inter\" })")); // a JS string literal
        QVERIFY(style.contains(R"(["lemonde.fr"])"));

        const auto user = Browser::userScript("console.log('global')", sites);
        QVERIFY(user.contains("console.log('global')"));
        QVERIFY(user.contains("if (matches(\"youtube.com\")) try {\ndocument.title='x'"));
        QVERIFY(!user.contains("alert(1)"));
        QVERIFY(Browser::cosmeticCss().contains("adsbygoogle"));
    }

    // ------------------------------------------------------------ assistant and icons
    void promptsTheAssistantWithThePage() {
        const auto prompt = PageAi::systemPrompt("fr", "Titre", "https://a.fr/", "Le texte.");
        QVERIFY(prompt.contains("français"));
        QVERIFY(prompt.contains("<titre>Titre</titre>"));
        QVERIFY(prompt.contains("Le texte."));
        QVERIFY(!PageAi::systemPrompt("en", "", "", "").contains("<page>"));
        QVERIFY(PageAi::systemPrompt("en", "", "", "").contains("English"));
    }

    void drawsTheLauncherIcon() {
        const auto svg = LauncherIcons::svgFor("flairweb", QColor("#5c9df5"), "plein");
        QVERIFY(svg.contains("#5c9df5"));
        QVERIFY(svg.contains("<circle"));
        QCOMPARE(LauncherIcons::svgFor("flairweb", QColor("#5c9df5"), "sombre").contains("#16110d"), true);

        // The launcher entry follows the accent when the app is installed.
        QTemporaryDir home, system;
        write(system.path() + "/flairweb.desktop", "[Desktop Entry]\nName=Flair Web\nIcon=flairweb\n");
        LauncherIcons::apply(QColor("#3ecf8e"), "plein", true, home.path(), system.path());
        QFile entry(home.path() + "/.local/share/applications/flairweb.desktop");
        QVERIFY(entry.open(QIODevice::ReadOnly));
        const auto text = entry.readAll();
        QVERIFY(text.contains("flairweb-plein-3ecf8e.svg"));
        QVERIFY(text.contains("X-Flair-Generated=true"));
    }
};

QTEST_MAIN(FlairWebTests)
#include "flairweb_tests.moc"
