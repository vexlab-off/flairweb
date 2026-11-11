#include "browser.h"
#include "dnr.h"
#include "extensionhost.h"

#include "settings.h"
#include "shield.h"

#include <QBuffer>
#include <QClipboard>
#include <QColor>
#include <QCryptographicHash>
#include <QDateTime>
#include <QImage>
#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QKeySequence>
#include <QLocale>
#include <QMouseEvent>
#include <QQuickWindow>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMetaObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QProcess>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <QWebEngineCookieStore>
#include <QWebEngineExtensionInfo>
#include <QWebEngineExtensionManager>
#include <QWebEngineScript>
#include <private/qzipreader_p.h>
#include <QtWebEngineQuick/QQuickWebEngineProfile>
#include <qtwebenginecoreversion.h>

Browser::Browser(BrowserSettings *settings, Shield *shield, const QStringList &startUrls, bool startPrivate,
                 QObject *parent)
    : QObject(parent),
      m_settings(settings),
      m_shield(shield),
      m_profile(new QQuickWebEngineProfile("flairweb", this)),
      m_private(new QQuickWebEngineProfile(this)),
      m_startUrls(startUrls),
      m_startPrivate(startPrivate) {
    m_private->setOffTheRecord(true);
    m_defaultAgent = m_profile->httpUserAgent();
    setUp(m_profile);
    setUp(m_private);
    // Data the settings asked to forget at exit is also cleared at start, in
    // case the last exit was too quick (or a crash) to finish the job.
    if (m_settings->value("privacy/clearCookiesOnExit").toBool())
        m_profile->cookieStore()->deleteAllCookies();
    if (m_settings->value("privacy/clearCacheOnExit").toBool())
        m_profile->clearHttpCache();

    connect(m_settings, &BrowserSettings::changed, this, &Browser::apply);
    if (qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG"))
        connect(this, &Browser::extensionMessage, this, [](const QString &m) { qInfo().noquote() << "[ext message]" << m; });
    connect(m_shield, &Shield::changed, this, &Browser::apply);
    apply();

    if (!m_profile->extensionManager())
        m_extensionsReady = true;
    if (auto *manager = m_profile->extensionManager()) {
        auto report = [this](const QWebEngineExtensionInfo &info) {
            if (!info.error().isEmpty())
                emit extensionMessage(QString("%1 : %2").arg(info.name().isEmpty() ? info.path() : info.name(), info.error()));
            emit extensionsChanged();
        };
        connect(manager, &QWebEngineExtensionManager::loadFinished, this, [this, report](const QWebEngineExtensionInfo &info) {
            // A folder that failed to load is done too: the pages don't wait for it.
            if (!info.error().isEmpty())
                m_failedLoads.insert(QFileInfo(info.path()).fileName().section('_', 0, 0));
            report(info);
            syncExtensions();
        });
        connect(manager, &QWebEngineExtensionManager::installFinished, this, [this, manager, report](const QWebEngineExtensionInfo &info) {
            // Qt installs extensions switched off; one asked for is wanted on.
            if (info.error().isEmpty() && info.isInstalled())
                setExtensionEnabled(info.id(), true);
            report(info);
            // The unwrapped .crx was only needed until Qt copied it.
            QDir(QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) + "/flairweb/extensions").removeRecursively();
            if (info.error().isEmpty() && info.isInstalled())
                emit extensionMessage("Extension installée : " + (info.name().isEmpty() ? info.id() : info.name()));
        });
        connect(manager, &QWebEngineExtensionManager::unloadFinished, this, report);
        // Qt loads installed extensions at start but switched off, and does
        // not remember which were on: the settings do.
        syncExtensions();
        QTimer::singleShot(0, this, &Browser::syncExtensions);
        // Never hold the first window back for long.
        QTimer::singleShot(3000, this, &Browser::setExtensionsReady);
        connect(manager, &QWebEngineExtensionManager::uninstallFinished, this, [this, manager, report](const QWebEngineExtensionInfo &info) {
            m_removing.remove(info.path());
            report(info);
            if (m_installAfterRemoval.contains(info.id()))
                manager->installExtension(m_installAfterRemoval.take(info.id()));
            // A removed extra copy: the kept one can be switched on now.
            syncExtensions();
        });
    }
}

void Browser::setUp(QQuickWebEngineProfile *profile) {
    // Extensions' network rules stay out of private tabs.
    profile->setUrlRequestInterceptor(profile == m_profile ? static_cast<QWebEngineUrlRequestInterceptor *>(m_shield)
                                                           : m_shield->privateInterceptor());
    // Third-party cookies: the filter runs on the network thread.
    profile->cookieStore()->setCookieFilter([this](const QWebEngineCookieStore::FilterRequest &request) {
        return !(request.thirdParty && m_blockThirdParty.load());
    });
}

QObject *Browser::profile() const { return m_profile; }
QObject *Browser::privateProfile() const { return m_private; }
QString Browser::version() const { return QCoreApplication::applicationVersion(); }
QString Browser::engineVersion() const {
    // "Chrome/134.0.…" from the default agent, plus Qt WebEngine's version.
    static const QRegularExpression chrome(R"(Chrome/([\d.]+))");
    const auto m = chrome.match(m_defaultAgent);
    return QString("Qt WebEngine %1%2").arg(QTWEBENGINECORE_VERSION_STR, m.hasMatch() ? " · Chromium " + m.captured(1) : QString());
}

void Browser::apply() {
    const auto agent = m_settings->userAgent();
    const auto language = m_settings->value("web/language").toString().trimmed();
    for (auto *profile : {m_profile, m_private}) {
        const auto wanted = agent.isEmpty() ? m_defaultAgent : agent;
        if (profile->httpUserAgent() != wanted)
            profile->setHttpUserAgent(wanted);
        if (!language.isEmpty() && profile->httpAcceptLanguage() != language)
            profile->setHttpAcceptLanguage(language);
        const auto dir = m_settings->downloadDirectory();
        if (profile->downloadPath() != dir)
            profile->setDownloadPath(dir);
    }
    const auto cookies = m_settings->value("privacy/cookies").toString() == "session"
                             ? QQuickWebEngineProfile::NoPersistentCookies
                             : QQuickWebEngineProfile::AllowPersistentCookies;
    if (m_profile->persistentCookiesPolicy() != cookies)
        m_profile->setPersistentCookiesPolicy(cookies);
    m_blockThirdParty.store(!m_settings->value("privacy/thirdPartyCookies").toBool());
    applyScripts(m_profile);
    applyScripts(m_private);
    m_scriptSignature.clear();
}

static QObject *scriptCollection(QQuickWebEngineProfile *profile) {
    return qvariant_cast<QObject *>(profile->property("userScripts"));
}

void Browser::applyScripts(QQuickWebEngineProfile *profile) {
    const bool cosmetic = m_settings->value("privacy/shield").toBool() && m_settings->value("privacy/cosmetic").toBool();
    QStringList allowed;
    for (const auto &line : m_settings->value("privacy/allowed").toString().split('\n', Qt::SkipEmptyParts))
        allowed.append(line.trimmed().toLower().remove(QRegularExpression("^www\\.")));
    const auto css = m_settings->value("style/css").toString();
    const auto js = m_settings->value("style/js").toString();
    const auto sites = m_settings->value("style/sites").toString();
    const auto signature = QString("%1\x1f%2\x1f%3\x1f%4\x1f%5\x1f%6").arg(cosmetic).arg(allowed.join(','), css, js, sites)
                               .arg(profile == m_profile ? m_extensionScriptsRevision : 0);
    if (profile->property("flairScripts").toString() == signature)
        return;
    profile->setProperty("flairScripts", signature);

    auto *collection = scriptCollection(profile);
    if (!collection)
        return;
    // Only our own scripts are ever in the collection: start from empty.
    QMetaObject::invokeMethod(collection, "clear");

    const auto style = styleScript(css, sites, cosmetic ? cosmeticCss() : QString(), allowed);
    if (!style.isEmpty()) {
        QWebEngineScript script;
        script.setName("flairweb-style");
        script.setSourceCode(style);
        script.setInjectionPoint(QWebEngineScript::DocumentCreation);
        script.setWorldId(QWebEngineScript::ApplicationWorld);
        script.setRunsOnSubFrames(true);
        QMetaObject::invokeMethod(collection, "insert", Q_ARG(QWebEngineScript, script));
    }
    // The Chrome Web Store: its "Add to Chrome" button installs here.
    if (extensionsSupported()) {
        QFile storeFile(":/extension/store.js");
        if (storeFile.open(QIODevice::ReadOnly)) {
            QWebEngineScript script;
            script.setName("flairweb-store");
            script.setSourceCode(QString::fromUtf8(storeFile.readAll()));
            script.setInjectionPoint(QWebEngineScript::DocumentReady);
            script.setWorldId(QWebEngineScript::ApplicationWorld);
            script.setRunsOnSubFrames(false);
            QMetaObject::invokeMethod(collection, "insert", Q_ARG(QWebEngineScript, script));
        }
    }
    const auto user = userScript(js, sites);
    if (!user.isEmpty()) {
        QWebEngineScript script;
        script.setName("flairweb-user");
        script.setSourceCode(user);
        script.setInjectionPoint(QWebEngineScript::DocumentReady);
        script.setWorldId(QWebEngineScript::MainWorld);
        script.setRunsOnSubFrames(false);
        QMetaObject::invokeMethod(collection, "insert", Q_ARG(QWebEngineScript, script));
    }
    if (profile != m_profile)
        return;
    // Extensions' scripts for the page's world, filtered by their match
    // patterns in the page (Chrome matches before injecting).
    for (auto it = m_extensionScripts.begin(); it != m_extensionScripts.end(); ++it) {
        const auto root = extensionPath(it.key());
        if (root.isEmpty())
            continue;
        for (const auto &v : *it) {
            const auto entry = v.toMap();
            QString code;
            for (const auto &file : entry.value("js").toStringList()) {
                const auto path = fileInside(root, file);
                QFile f(path);
                if (!path.isEmpty() && f.open(QIODevice::ReadOnly))
                    code += QString::fromUtf8(f.readAll()) + "\n;\n";
            }
            if (code.isEmpty())
                continue;
            const auto matches = QJsonDocument(QJsonArray::fromStringList(entry.value("matches").toStringList())).toJson(QJsonDocument::Compact);
            const auto excludes = QJsonDocument(QJsonArray::fromStringList(entry.value("excludeMatches").toStringList())).toJson(QJsonDocument::Compact);
            QWebEngineScript script;
            script.setName("flairweb-ext:" + it.key() + ":" + entry.value("id").toString());
            script.setSourceCode(QString(R"js((() => {
const href = location.href;
const test = (p) => {
    if (p === '<all_urls>' || p === '*') return /^(https?|wss?|file|ftp):/.test(href);
    const m = /^(\*|[a-z-]+):\/\/([^/]*)(\/.*)?$/.exec(p);
    const u = /^([a-z-]+):\/\/([^/:]*)(?::\d+)?(\/[^#]*)?/i.exec(href);
    if (!m || !u) return false;
    if (m[1] === '*' ? !/^https?$/.test(u[1]) : m[1] !== u[1]) return false;
    const h = m[2], host = u[2];
    if (!(h === '*' || h === host || (h.startsWith('*.') && (host === h.slice(2) || host.endsWith(h.slice(1)))))) return false;
    const path = new RegExp('^' + (m[3] || '/*').replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
    return path.test(u[3] || '/');
};
if (!%1.some(test) || %2.some(test)) return;
%3
})();)js").arg(QString::fromUtf8(matches), QString::fromUtf8(excludes), code));
            const auto runAt = entry.value("runAt").toString();
            script.setInjectionPoint(runAt == "document_end" ? QWebEngineScript::DocumentReady
                                     : runAt == "document_idle" ? QWebEngineScript::Deferred
                                                                : QWebEngineScript::DocumentCreation);
            script.setWorldId(QWebEngineScript::MainWorld);
            script.setRunsOnSubFrames(entry.value("allFrames").toBool());
            QMetaObject::invokeMethod(collection, "insert", Q_ARG(QWebEngineScript, script));
        }
    }
}

void Browser::setExtensionsReady() {
    if (m_extensionsReady)
        return;
    m_extensionsReady = true;
    emit extensionsReadyChanged();
}

void Browser::setExtensionSupport(ExtensionHost *host, Dnr *dnr) {
    m_host = host;
    m_dnr = dnr;
    syncExtensions();
}

QString Browser::extensionPath(const QString &id) const {
    auto *manager = m_profile->extensionManager();
    if (!manager)
        return {};
    for (const auto &info : manager->extensions())
        if (info.id() == id)
            return info.path();
    return {};
}

QString Browser::fileInside(const QString &root, const QString &relative) {
    if (root.isEmpty())
        return {};
    const auto base = QFileInfo(root).canonicalFilePath();
    auto name = relative;
    name.remove(QRegularExpression("^/+"));
    const auto file = QFileInfo(QDir::cleanPath(root + "/" + name)).canonicalFilePath();
    if (base.isEmpty() || file.isEmpty() || !file.startsWith(base + "/") || !QFileInfo(file).isFile())
        return {};
    return file;
}

QString Browser::extensionFile(const QString &id, const QString &relative) const {
    return fileInside(extensionPath(id), relative);
}

QString Browser::readExtensionFile(const QString &id, const QString &relative) const {
    const auto path = extensionFile(id, relative);
    QFile file(path);
    return !path.isEmpty() && file.open(QIODevice::ReadOnly) ? QString::fromUtf8(file.readAll()) : QString();
}

void Browser::setExtensionScripts(const QString &id, const QVariantList &scripts) {
    if (scripts.isEmpty() && !m_extensionScripts.contains(id))
        return;
    if (scripts.isEmpty())
        m_extensionScripts.remove(id);
    else
        m_extensionScripts.insert(id, scripts);
    ++m_extensionScriptsRevision;
    applyScripts(m_profile);
}

int Browser::dnrBlockedOn(const QString &id, const QString &pageUrl) const {
    return m_dnr ? m_dnr->blockedOn(id, pageUrl) : 0;
}

bool Browser::dnrCountsOnBadge(const QString &id) const {
    if (!m_dnr || !m_dnr->hasExtension(id))
        return false;
    QString error;
    return m_dnr->call(id, "actionCountBadge", {}, &error).toBool();
}

void Browser::notify(const QString &title, const QString &message, const QString &icon) const {
    QStringList args{"-a", "Flair Web"};
    if (!icon.isEmpty())
        args << "-i" << localPath(icon);
    args << title << message;
    QProcess::startDetached("notify-send", args);
}

QString Browser::imageDataUrl(const QVariant &image, const QString &format, int quality) const {
    const auto img = image.value<QImage>();
    if (img.isNull())
        return {};
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    const bool jpeg = format == "jpeg";
    img.save(&buffer, jpeg ? "JPEG" : "PNG", jpeg ? (quality > 0 ? quality : 92) : -1);
    return QString("data:image/%1;base64,%2").arg(jpeg ? "jpeg" : "png", QString::fromLatin1(bytes.toBase64()));
}

QString Browser::cosmeticCss() {
    return QStringLiteral(
        ".adsbygoogle, ins.adsbygoogle, [id^=\"google_ads_\"], [id^=\"div-gpt-ad\"], [data-ad-slot], "
        "[data-google-query-id], [data-ad-unit], .ad-slot, .ad-banner, .adsbox, .advertisement, .adunit, "
        "[id^=\"taboola-\"], .trc_related_container, .OUTBRAIN, [data-widget-id^=\"AR_\"], "
        "iframe[src*=\"doubleclick.net\"], iframe[src*=\"googlesyndication\"], iframe[id^=\"google_ads_iframe\"], "
        "amp-ad, amp-embed[type=\"taboola\"], amp-embed[type=\"outbrain\"] "
        "{ display: none !important; }");
}

bool Browser::sitePatternMatches(const QString &rawPattern, const QString &rawHost) {
    auto pattern = rawPattern.trimmed().toLower();
    auto host = rawHost.toLower();
    if (pattern.startsWith("www."))
        pattern = pattern.mid(4);
    if (host.startsWith("www."))
        host = host.mid(4);
    if (pattern.isEmpty())
        return false;
    if (pattern == "*")
        return true;
    if (pattern.contains('*')) {
        const auto re = QRegularExpression::wildcardToRegularExpression(pattern, QRegularExpression::NonPathWildcardConversion);
        return QRegularExpression(re).match(host).hasMatch();
    }
    return host == pattern || host.endsWith("." + pattern);
}

// The same matching as sitePatternMatches, in the page.
static const char *kMatchJs = R"JS(
  var host = (location.hostname || '').toLowerCase().replace(/^www\./, '');
  function matches(p) {
    p = String(p || '').trim().toLowerCase().replace(/^www\./, '');
    if (!p) return false;
    if (p === '*') return true;
    if (p.indexOf('*') >= 0) {
      var re = new RegExp('^' + p.split('*').map(function (s) { return s.replace(/[.+?^${}()|[\]\\]/g, '\\$&'); }).join('.*') + '$');
      return re.test(host);
    }
    return host === p || host.slice(-(p.length + 1)) === '.' + p;
  }
)JS";

static QString jsString(const QString &text) {
    // A JSON string literal is a valid JS string literal.
    const auto json = QJsonDocument(QJsonArray{text}).toJson(QJsonDocument::Compact);
    return QString::fromUtf8(json.mid(1, json.size() - 2));
}

QString Browser::styleScript(const QString &globalCss, const QString &sitesJson, const QString &cosmetic,
                             const QStringList &allowedSites) {
    const auto sites = QJsonDocument::fromJson(sitesJson.toUtf8()).array();
    QJsonArray rules;
    for (const auto &v : sites) {
        const auto o = v.toObject();
        if (o.value("enabled").toBool(true) && !o.value("css").toString().trimmed().isEmpty())
            rules.append(QJsonObject{{"pattern", o.value("pattern")}, {"css", o.value("css")}});
    }
    if (globalCss.trimmed().isEmpty() && rules.isEmpty() && cosmetic.isEmpty())
        return {};
    return QString(R"JS((function () {%1
  var rules = %2, css = %3, cosmetic = %4, allowed = %5;
  rules.forEach(function (r) { if (matches(r.pattern)) css += '\n' + r.css; });
  if (cosmetic && allowed.indexOf(host) < 0) css += '\n' + cosmetic;
  if (!css.trim()) return;
  function inject() {
    var root = document.head || document.documentElement;
    if (!root) return false;
    var style = document.createElement('style');
    style.id = 'flairweb-style';
    style.textContent = css;
    root.appendChild(style);
    return true;
  }
  if (!inject()) document.addEventListener('readystatechange', function once() {
    if (inject()) document.removeEventListener('readystatechange', once);
  });
})();)JS")
        .arg(QString::fromUtf8(kMatchJs), QString::fromUtf8(QJsonDocument(rules).toJson(QJsonDocument::Compact)),
             jsString(globalCss), jsString(cosmetic),
             QString::fromUtf8(QJsonDocument(QJsonArray::fromStringList(allowedSites)).toJson(QJsonDocument::Compact)));
}

QString Browser::userScript(const QString &globalJs, const QString &sitesJson) {
    // Each script is pasted as code, not evaluated from a string, so pages
    // whose Content-Security-Policy forbids eval still run it.
    QString blocks;
    if (!globalJs.trimmed().isEmpty())
        blocks += QString("  try {\n%1\n  } catch (e) { console.error('Flair Web (script global) :', e); }\n").arg(globalJs);
    for (const auto &v : QJsonDocument::fromJson(sitesJson.toUtf8()).array()) {
        const auto o = v.toObject();
        const auto js = o.value("js").toString();
        if (!o.value("enabled").toBool(true) || js.trimmed().isEmpty())
            continue;
        blocks += QString("  if (matches(%1)) try {\n%2\n  } catch (e) { console.error('Flair Web (%3) :', e); }\n")
                      .arg(jsString(o.value("pattern").toString()), js, o.value("pattern").toString().remove('\'').remove('\\'));
    }
    if (blocks.isEmpty())
        return {};
    return QString("(function () {%1\n%2})();").arg(QString::fromUtf8(kMatchJs), blocks);
}

// ---------------------------------------------------------------- desktop

void Browser::copy(const QString &text) const { QGuiApplication::clipboard()->setText(text); }
QString Browser::clipboardText() const { return QGuiApplication::clipboard()->text(); }

void Browser::openExternally(const QString &url) const { QDesktopServices::openUrl(QUrl(url)); }

bool Browser::hasFlair() const { return !QStandardPaths::findExecutable("flair").isEmpty(); }

QString Browser::localPath(const QString &url) const {
    if (url.startsWith("file:"))
        return QUrl(url).toLocalFile();
    return url;
}

QString Browser::fileUrl(const QString &path) const { return QUrl::fromLocalFile(path).toString(); }
bool Browser::fileExists(const QString &path) const { return QFileInfo::exists(localPath(path)); }
QString Browser::homePath() const { return QDir::homePath(); }
QString Browser::dataPath(const QString &name) const {
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/flairweb/" + name;
}

QString Browser::writeRuntimeFile(const QString &name, const QString &text) const {
    auto dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (dir.isEmpty())
        dir = QDir::tempPath();
    dir += "/flairweb";
    QDir().mkpath(dir);
    QFile::setPermissions(dir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    const auto path = dir + "/" + QFileInfo(name).fileName();
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(text.toUtf8()) < 0 || !file.commit())
        return {};
    return QUrl::fromLocalFile(path).toString();
}

void Browser::openInFlair(const QString &rawPath) const {
    const auto path = localPath(rawPath);
    if (hasFlair() && QProcess::startDetached("flair", {path}))
        return;
    QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

void Browser::openFile(const QString &rawPath) const {
    QDesktopServices::openUrl(QUrl::fromLocalFile(localPath(rawPath)));
}

void Browser::showInFolder(const QString &rawPath) const {
    const QFileInfo info(localPath(rawPath));
    const auto folder = info.isDir() ? info.absoluteFilePath() : info.absolutePath();
    if (hasFlair() && QProcess::startDetached("flair", {folder}))
        return;
    QDesktopServices::openUrl(QUrl::fromLocalFile(folder));
}

void Browser::launch(const QString &program, const QStringList &arguments) const {
    QProcess::startDetached(program, arguments);
}

bool Browser::isDefaultBrowser() const {
    QProcess process;
    process.start("xdg-settings", {"get", "default-web-browser"});
    if (!process.waitForFinished(3000))
        return false;
    return QString::fromUtf8(process.readAllStandardOutput()).trimmed() == "flairweb.desktop";
}

bool Browser::makeDefaultBrowser() const {
    QProcess process;
    process.start("xdg-settings", {"set", "default-web-browser", "flairweb.desktop"});
    return process.waitForFinished(5000) && process.exitCode() == 0;
}

QString Browser::humanSize(double bytes) const {
    if (bytes < 0)
        return "?";
    static const char *units[] = {"o", "Ko", "Mo", "Go", "To"};
    int unit = 0;
    while (bytes >= 1024 && unit < 4) {
        bytes /= 1024;
        ++unit;
    }
    return QLocale().toString(bytes, 'f', unit == 0 || bytes >= 100 ? 0 : 1) + " " + units[unit];
}

QString Browser::uniquePath(const QString &directory, const QString &name) const {
    const QFileInfo info(name);
    QString candidate = directory + "/" + name;
    for (int i = 2; QFileInfo::exists(candidate); ++i)
        candidate = QString("%1/%2 (%3)%4").arg(directory, info.completeBaseName()).arg(i).arg(info.suffix().isEmpty() ? QString() : "." + info.suffix());
    return candidate;
}

QString Browser::readText(const QString &path) const {
    QFile file(localPath(path));
    return file.open(QIODevice::ReadOnly) ? QString::fromUtf8(file.readAll()) : QString();
}

bool Browser::writeText(const QString &path, const QString &text) const {
    QSaveFile file(localPath(path));
    return file.open(QIODevice::WriteOnly) && file.write(text.toUtf8()) >= 0 && file.commit();
}

// ---------------------------------------------------------------- development

QElapsedTimer &Browser::startupClock() {
    static QElapsedTimer clock;
    return clock;
}

void Browser::startupMark(const QString &step) {
    static const bool on = qEnvironmentVariableIsSet("FLAIRWEB_STARTUP_LOG");
    if (on && startupClock().isValid())
        qInfo().noquote() << QString("[start] %1 ms  %2").arg(startupClock().elapsed(), 5).arg(step);
}

void Browser::devMouse(QObject *object, const QString &kind, qreal x, qreal y, int button) const {
    auto *window = qobject_cast<QQuickWindow *>(object);
    if (!window)
        return;
    const QPointF local(x, y);
    const QPointF global = window->mapToGlobal(local);
    const auto b = button == 2 ? Qt::RightButton : button == 4 ? Qt::MiddleButton : Qt::LeftButton;
    auto send = [&](QEvent::Type type, Qt::MouseButton which, Qt::MouseButtons held) {
        QMouseEvent event(type, local, local, global, which, held, Qt::NoModifier);
        QCoreApplication::sendEvent(window, &event);
    };
    // A move first, as a real pointer would: hover states follow it.
    send(QEvent::MouseMove, Qt::NoButton, Qt::NoButton);
    if (kind == "press" || kind == "click" || kind == "double")
        send(QEvent::MouseButtonPress, b, b);
    if (kind == "release" || kind == "click" || kind == "double")
        send(QEvent::MouseButtonRelease, b, Qt::NoButton);
    if (kind == "double") {
        send(QEvent::MouseButtonPress, b, b);
        send(QEvent::MouseButtonDblClick, b, b);
        send(QEvent::MouseButtonRelease, b, Qt::NoButton);
    }
}

void Browser::devType(QObject *object, const QString &text) const {
    auto *window = qobject_cast<QQuickWindow *>(object);
    if (!window)
        return;
    for (const QChar c : text) {
        QKeyEvent press(QEvent::KeyPress, 0, Qt::NoModifier, QString(c));
        QCoreApplication::sendEvent(window, &press);
        QKeyEvent release(QEvent::KeyRelease, 0, Qt::NoModifier, QString(c));
        QCoreApplication::sendEvent(window, &release);
    }
}

void Browser::devKey(QObject *object, const QString &sequence) const {
    auto *window = qobject_cast<QQuickWindow *>(object);
    const QKeySequence keys(sequence);
    if (!window || keys.isEmpty())
        return;
    const auto combo = keys[0];
    QKeyEvent press(QEvent::KeyPress, combo.key(), combo.keyboardModifiers());
    QCoreApplication::sendEvent(window, &press);
    QKeyEvent release(QEvent::KeyRelease, combo.key(), combo.keyboardModifiers());
    QCoreApplication::sendEvent(window, &release);
}

bool Browser::devGrab(QObject *object, const QString &path) const {
    auto *window = qobject_cast<QQuickWindow *>(object);
    return window && window->grabWindow().save(path);
}

// ---------------------------------------------------------------- data

void Browser::clearCookies() {
    m_profile->cookieStore()->deleteAllCookies();
    m_private->cookieStore()->deleteAllCookies();
}

void Browser::clearCache() {
    m_profile->clearHttpCache();
    m_private->clearHttpCache();
}

void Browser::clearPrivateData() {
    // Cookies, cache, local storage, IndexedDB: everything lives in the
    // off-the-record profile, so the next private tab gets a new one.
    auto *old = m_private;
    m_private = new QQuickWebEngineProfile(this);
    m_private->setOffTheRecord(true);
    setUp(m_private);
    apply();
    emit privateProfileChanged();
    old->cookieStore()->deleteAllCookies();
    old->deleteLater();
}

void Browser::shutdown() {
    // Chromium trips over a profile destroyed with extensions still running:
    // switch them off first (Qt doesn't keep that state; our settings do).
    if (auto *manager = m_profile->extensionManager())
        for (const auto &info : manager->extensions())
            if (info.isInstalled() && info.isEnabled())
                manager->setExtensionEnabled(info, false);
    if (m_settings->value("privacy/clearCookiesOnExit").toBool())
        m_profile->cookieStore()->deleteAllCookies();
    if (m_settings->value("privacy/clearCacheOnExit").toBool())
        m_profile->clearHttpCache();
}

// ---------------------------------------------------------------- extensions

bool Browser::extensionsSupported() const { return m_profile->extensionManager() != nullptr; }

QString Browser::extensionsPath() const {
    auto *manager = m_profile->extensionManager();
    return manager ? manager->installPath() : QString();
}

QVariantList Browser::extensions() const {
    QVariantList out;
    auto *manager = m_profile->extensionManager();
    if (!manager)
        return out;
    QSet<QString> listed;
    const auto preferred = preferredExtensionPaths();
    for (const auto &info : manager->extensions()) {
        // The same extension installed twice shows once: the copy in use.
        if (listed.contains(info.id()) || (info.isInstalled() && preferred.value(info.id()) != info.path()))
            continue;
        listed.insert(info.id());
        QFile file(info.path() + "/manifest.json");
        const auto manifest = file.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(file.readAll()).object() : QJsonObject();
        const auto action = manifest.value("action").toObject();
        // The icon closest to 32 px, from the action or the extension.
        auto icons = action.value("default_icon");
        if (!icons.isObject() && !icons.isString())
            icons = manifest.value("icons");
        QString icon = icons.isString() ? icons.toString() : QString();
        if (icons.isObject()) {
            int best = 0;
            const auto o = icons.toObject();
            for (auto it = o.begin(); it != o.end(); ++it) {
                const int size = it.key().toInt();
                if (!best || (size >= 32 && (best < 32 || size < best)) || (best < 32 && size > best)) {
                    best = size;
                    icon = it.value().toString();
                }
            }
        }
        if (!icon.isEmpty())
            icon = QUrl::fromLocalFile(QDir::cleanPath(info.path() + "/" + icon)).toString();
        out.append(QVariantMap{{"id", info.id()},
                               {"icon", icon},
                               {"version", manifest.value("version").toString()},
                               {"hasAction", manifest.contains("action") || manifest.contains("browser_action")},
                               {"hasWorker", !manifest.value("background").toObject().value("service_worker").toString().isEmpty()},
                               {"defaultPopup", action.value("default_popup").toString().isEmpty()
                                                    ? QString()
                                                    : "chrome-extension://" + info.id() + "/" + action.value("default_popup").toString().remove(QRegularExpression("^/+"))},
                               {"actionTitle", action.value("default_title").toString()},
                               {"optionsPage", manifest.value("options_ui").toObject().value("page").toString().isEmpty()
                                                   ? manifest.value("options_page").toString()
                                                   : manifest.value("options_ui").toObject().value("page").toString()},
                               {"name", info.name()},
                               {"description", info.description()},
                               {"path", info.path()},
                               {"error", info.error()},
                               {"popup", info.actionPopupUrl().toString()},
                               {"enabled", info.isEnabled()},
                               {"loaded", info.isLoaded()},
                               {"installed", info.isInstalled()}});
    }
    return out;
}

void Browser::installExtension(const QString &rawPath) {
    auto *manager = m_profile->extensionManager();
    if (!manager)
        return;
    const auto path = localPath(rawPath);
    if (!QFileInfo::exists(path)) {
        emit extensionMessage("Introuvable : " + path);
        return;
    }
    // Archives (.crx, .zip) are unpacked; folders copied. Either way the copy
    // gets the bridge before Qt installs it.
    if (QFileInfo(path).isFile()) {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            emit extensionMessage("Illisible : " + path);
            return;
        }
        const auto data = file.readAll();
        installZip(crxToZip(data), QFileInfo(path).completeBaseName(), crxPublicKey(data));
        return;
    }
    QString error;
    const auto dir = m_host ? m_host->prepareFolder(path, &error) : path;
    if (dir.isEmpty()) {
        emit extensionMessage("Extension refusée : " + error);
        return;
    }
    manager->installExtension(dir);
}

QByteArray Browser::crxToZip(const QByteArray &data) {
    if (data.startsWith("PK\x03\x04"))
        return data;
    if (!data.startsWith("Cr24") || data.size() < 16)
        return {};
    auto le32 = [&](int at) {
        return quint32(uchar(data[at])) | quint32(uchar(data[at + 1])) << 8 | quint32(uchar(data[at + 2])) << 16
               | quint32(uchar(data[at + 3])) << 24;
    };
    qint64 offset = -1;
    const auto version = le32(4);
    if (version == 3)
        offset = 12 + qint64(le32(8));                          // CRX3: protobuf header
    else if (version == 2)
        offset = 16 + qint64(le32(8)) + qint64(le32(12));       // CRX2: key + signature
    if (offset <= 0 || offset >= data.size() || !data.mid(offset, 4).startsWith("PK\x03\x04"))
        return {};
    return data.mid(offset);
}

namespace {
// Minimal protobuf reading for the CRX3 header.
bool readVarint(const QByteArray &d, int &i, quint64 &out) {
    out = 0;
    for (int shift = 0; i < d.size() && shift < 64; shift += 7) {
        const auto b = quint8(d[i++]);
        out |= quint64(b & 0x7f) << shift;
        if (!(b & 0x80))
            return true;
    }
    return false;
}
// Length-delimited fields of a message: field number -> values.
QMultiHash<int, QByteArray> protoFields(const QByteArray &d) {
    QMultiHash<int, QByteArray> out;
    int i = 0;
    while (i < d.size()) {
        quint64 tag = 0, value = 0;
        if (!readVarint(d, i, tag))
            break;
        const int wire = int(tag & 7);
        if (wire == 2) {
            if (!readVarint(d, i, value) || i + qint64(value) > d.size())
                break;
            out.insert(int(tag >> 3), d.mid(i, int(value)));
            i += int(value);
        } else if (wire == 0) {
            readVarint(d, i, value);
        } else if (wire == 5) {
            i += 4;
        } else if (wire == 1) {
            i += 8;
        } else {
            break;
        }
    }
    return out;
}
} // namespace

QString Browser::extensionIdForKey(const QByteArray &key) {
    const auto hash = QCryptographicHash::hash(key, QCryptographicHash::Sha256).left(16).toHex();
    QString id;
    for (const char c : hash)
        id += QChar('a' + (c >= 'a' ? c - 'a' + 10 : c - '0'));
    return id;
}

QByteArray Browser::crxPublicKey(const QByteArray &data) {
    if (!data.startsWith("Cr24") || data.size() < 16)
        return {};
    auto le32 = [&](int at) {
        return quint32(uchar(data[at])) | quint32(uchar(data[at + 1])) << 8 | quint32(uchar(data[at + 2])) << 16
               | quint32(uchar(data[at + 3])) << 24;
    };
    if (le32(4) == 2)
        return data.mid(16, int(le32(8)));
    if (le32(4) != 3)
        return {};
    const auto header = protoFields(data.mid(12, int(le32(8))));
    const auto signedData = protoFields(header.value(10000));
    const auto crxId = signedData.value(1);
    QByteArray first;
    for (int field : {2, 3})
        for (const auto &proof : header.values(field)) {
            const auto key = protoFields(proof).value(1);
            if (first.isEmpty())
                first = key;
            if (!crxId.isEmpty() && QCryptographicHash::hash(key, QCryptographicHash::Sha256).left(16) == crxId)
                return key;
        }
    return first;
}

void Browser::installZip(const QByteArray &zip, const QString &name, const QByteArray &key) {
    auto *manager = m_profile->extensionManager();
    if (!manager)
        return;
    if (zip.isEmpty()) {
        emit extensionMessage("Ce fichier n'est pas une extension (.crx ou .zip).");
        return;
    }
    // A theme is not an extension: Flair Web applies it itself.
    if (installTheme(zip, key.isEmpty() ? name : extensionIdForKey(key)))
        return;
    QString error;
    const auto dir = m_host ? m_host->prepareZip(zip, name, &error, key) : QString();
    if (dir.isEmpty()) {
        emit extensionMessage("Extension refusée : " + error);
        return;
    }
    // Already installed (an update, a second click): the new copy replaces
    // the old one once it is uninstalled, never next to it.
    const auto id = key.isEmpty() ? QString() : extensionIdForKey(key);
    for (const auto &info : manager->extensions())
        if (!id.isEmpty() && info.id() == id && info.isInstalled()) {
            m_installAfterRemoval.insert(id, dir);
            manager->uninstallExtension(info);
            return;
        }
    manager->installExtension(dir);
}

namespace {
QColor themeColor(const QJsonValue &value) {
    const auto a = value.toArray();
    if (a.size() < 3)
        return {};
    QColor c(qBound(0, a.at(0).toInt(), 255), qBound(0, a.at(1).toInt(), 255), qBound(0, a.at(2).toInt(), 255));
    if (a.size() >= 4)
        c.setAlphaF(qBound(0.0, a.at(3).toDouble(1.0), 1.0));
    return c;
}
double luminance(const QColor &c) { return 0.2126 * c.redF() + 0.7152 * c.greenF() + 0.0722 * c.blueF(); }
} // namespace

QVariantMap Browser::chromeThemeColors(const QJsonObject &theme) {
    const auto colors = theme.value("colors").toObject();
    QVariantMap out;
    // Light or dark from the browser's own surfaces.
    QColor chrome;
    for (const auto key : {"toolbar", "frame", "ntp_background"}) {
        chrome = themeColor(colors.value(key));
        if (chrome.isValid())
            break;
    }
    const bool dark = chrome.isValid() && luminance(chrome) < 0.5;
    if (chrome.isValid())
        out["mode"] = dark ? "dark" : "light";
    // The accent: the most vivid colour the theme has, links and buttons
    // first; a theme in greys keeps the current accent.
    QColor best;
    double bestScore = 0;
    for (auto it = colors.begin(); it != colors.end(); ++it) {
        const auto c = themeColor(it.value());
        if (!c.isValid() || c.hsvSaturationF() < 0.35 || c.lightnessF() < 0.2 || c.lightnessF() > 0.85)
            continue;
        double score = c.hsvSaturationF() * c.valueF();
        if (it.key() == "ntp_link" || it.key() == "button_background" || it.key() == "toolbar_button_icon")
            score *= 1.15;
        if (score > bestScore) {
            bestScore = score;
            best = c;
        }
    }
    if (best.isValid())
        out["accent"] = best.name();
    // The new tab's colour, when it goes with the mode (text stays readable).
    const auto ntp = themeColor(colors.value("ntp_background"));
    if (ntp.isValid() && (!chrome.isValid() || (luminance(ntp) < 0.5) == dark))
        out["ntpColor"] = ntp.name();
    return out;
}

bool Browser::installTheme(const QByteArray &zip, const QString &id) {
    QBuffer buffer;
    buffer.setData(zip);
    buffer.open(QIODevice::ReadOnly);
    QZipReader reader(&buffer);
    if (!reader.isReadable() || reader.status() != QZipReader::NoError)
        return false;
    for (const auto &info : reader.fileInfoList())
        if (info.size > 64LL * 1024 * 1024)
            return false;   // not a theme (they are small): the extension path decides
    // The manifest at the root, or in the archive's single folder.
    QString prefix;
    auto manifestData = reader.fileData("manifest.json");
    if (manifestData.isEmpty())
        for (const auto &info : reader.fileInfoList())
            if (info.filePath.count('/') == 1 && info.filePath.endsWith("/manifest.json")) {
                prefix = info.filePath.left(info.filePath.size() - int(strlen("manifest.json")));
                manifestData = reader.fileData(info.filePath);
                break;
            }
    const auto manifest = QJsonDocument::fromJson(manifestData).object();
    const auto theme = manifest.value("theme").toObject();
    if (theme.isEmpty())
        return false;

    // "__MSG_appName__" names come from the default locale's messages.
    auto name = manifest.value("name").toString();
    static const QRegularExpression message("^__MSG_(\\w+)__$");
    if (const auto m = message.match(name); m.hasMatch()) {
        const auto locale = manifest.value("default_locale").toString("en");
        const auto messages = QJsonDocument::fromJson(reader.fileData(prefix + "_locales/" + locale + "/messages.json")).object();
        for (auto it = messages.begin(); it != messages.end(); ++it)
            if (it.key().compare(m.captured(1), Qt::CaseInsensitive) == 0)
                name = it.value().toObject().value("message").toString();
    }
    if (name.isEmpty() || name.startsWith("__MSG_"))
        name = "Thème Chrome";

    QString safeId = id;
    safeId.remove(QRegularExpression("[^A-Za-z0-9_.-]"));
    if (safeId.isEmpty())
        safeId = "theme";
    const auto dir = dataPath("themes/" + safeId);
    // One theme at a time: the previous one's files go.
    QDir(dataPath("themes")).removeRecursively();
    QDir().mkpath(dir);

    auto info = chromeThemeColors(theme);
    info["id"] = safeId;
    info["name"] = name;
    // The new tab picture, read from inside the archive (never outside it).
    const auto picture = QDir::cleanPath(theme.value("images").toObject().value("theme_ntp_background").toString());
    if (!picture.isEmpty() && picture != "." && !picture.startsWith("..") && !QDir::isAbsolutePath(picture)) {
        QImage image;
        if (image.loadFromData(reader.fileData(prefix + picture)) && !image.isNull()) {
            if (image.width() > 3840)
                image = image.scaledToWidth(3840, Qt::SmoothTransformation);
            const auto path = dir + "/ntp.png";
            if (image.save(path, "PNG"))
                info["image"] = QUrl::fromLocalFile(path).toString();
        }
    }
    m_settings->set("appearance/chromeTheme", QString::fromUtf8(QJsonDocument(QJsonObject::fromVariantMap(info)).toJson(QJsonDocument::Compact)));
    emit extensionMessage("Thème installé : " + name);
    return true;
}

void Browser::removeChromeTheme() {
    QDir(dataPath("themes")).removeRecursively();
    m_settings->set("appearance/chromeTheme", "");
    emit extensionMessage("Thème retiré : les couleurs de Flair Web reviennent.");
}

QString Browser::extensionIdIn(const QString &linkOrId) {
    static const QRegularExpression id(R"((?:^|[/=])([a-p]{32})(?:[/?#&]|$))");
    const auto m = id.match(linkOrId.trimmed());
    return m.hasMatch() ? m.captured(1) : QString();
}

void Browser::setInstalling(bool on) {
    if (m_installing == on)
        return;
    m_installing = on;
    emit installingChanged();
}

void Browser::installFromStore(const QString &linkOrId) {
    if (!m_profile->extensionManager() || m_installing)
        return;
    const auto id = extensionIdIn(linkOrId);
    if (id.isEmpty()) {
        emit extensionMessage("Pas de lien d'extension reconnu : colle l'adresse de sa page sur le Chrome Web Store.");
        return;
    }
    if (!m_network)
        m_network = new QNetworkAccessManager(this);
    // The update service Chromium uses, which answers with the .crx for the
    // engine's Chromium version.
    static const QRegularExpression chrome(R"(Chrome/([\d.]+))");
    const auto m = chrome.match(m_defaultAgent);
    QUrl url("https://clients2.google.com/service/update2/crx");
    url.setQuery(QString("response=redirect&acceptformat=crx2,crx3&prodversion=%1&x=id%3D%2%26installsource%3Dondemand%26uc")
                     .arg(m.hasMatch() ? m.captured(1) : "140.0.0.0", id));
    QNetworkRequest request(url);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setHeader(QNetworkRequest::UserAgentHeader, m_defaultAgent);
    // A stalled download must not block the next installs until restart.
    request.setTransferTimeout(60000);
    setInstalling(true);
    emit extensionMessage("Téléchargement de l'extension…");
    auto *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, id] {
        reply->deleteLater();
        setInstalling(false);
        const auto data = reply->readAll();
        if (reply->error() != QNetworkReply::NoError || data.isEmpty()) {
            emit extensionMessage("Téléchargement impossible : " + (data.isEmpty() && reply->error() == QNetworkReply::NoError
                                                                          ? QString("le Web Store n'a rien renvoyé (extension retirée ou réservée à Chrome ?)")
                                                                          : reply->errorString()));
            return;
        }
        installZip(crxToZip(data), id, crxPublicKey(data));
    });
}

void Browser::uninstallExtension(const QString &id) {
    auto *manager = m_profile->extensionManager();
    if (!manager)
        return;
    for (const auto &info : manager->extensions())
        if (info.id() == id) {
            if (info.isInstalled())
                manager->uninstallExtension(info);
            else
                manager->unloadExtension(info);
            return;
        }
}

void Browser::setExtensionEnabled(const QString &id, bool enabled) {
    auto off = m_settings->value("extensions/disabled").toString().split(',', Qt::SkipEmptyParts);
    off.removeAll(id);
    if (!enabled)
        off.append(id);
    m_settings->set("extensions/disabled", off.join(','));
    syncExtensions();
}

int Browser::setAsideDuplicateExtensions(const QString &installDir, const QString &asideDir) {
    // Folders are "<id>_<suffix>".
    QHash<QString, QStringList> byId;
    for (const auto &entry : QDir(installDir).entryList(QDir::Dirs | QDir::NoDotAndDotDot))
        if (QFile::exists(installDir + "/" + entry + "/manifest.json") && entry.contains('_'))
            byId[entry.section('_', 0, 0)].append(entry);
    auto score = [&installDir](const QString &entry) {
        const QFileInfo prepared(installDir + "/" + entry + "/flair/patch.json");
        return prepared.exists() ? (qint64(1) << 40) + prepared.lastModified().toSecsSinceEpoch()
                                 : QFileInfo(installDir + "/" + entry).lastModified().toSecsSinceEpoch();
    };
    int moved = 0;
    for (auto it = byId.begin(); it != byId.end(); ++it) {
        if (it->size() < 2)
            continue;
        auto copies = *it;
        std::sort(copies.begin(), copies.end(), [&score](const QString &a, const QString &b) { return score(a) > score(b); });
        QDir().mkpath(asideDir);
        for (int i = 1; i < copies.size(); ++i) {
            const auto target = asideDir + "/" + copies[i] + "-" + QString::number(QDateTime::currentSecsSinceEpoch());
            if (QDir().rename(installDir + "/" + copies[i], target))
                ++moved;
        }
    }
    return moved;
}

QHash<QString, QString> Browser::preferredExtensionPaths() const {
    // The same extension installed more than once (a reinstall, an update):
    // Chromium runs only one copy per id. The one kept is the newest copy
    // prepared for Flair Web.
    QHash<QString, QString> paths;
    QHash<QString, qint64> scores;
    auto *manager = m_profile->extensionManager();
    if (!manager)
        return paths;
    for (const auto &info : manager->extensions()) {
        if (!info.isInstalled())
            continue;
        const QFileInfo prepared(info.path() + "/flair/patch.json");
        const qint64 score = prepared.exists() ? (qint64(1) << 40) + prepared.lastModified().toSecsSinceEpoch()
                                               : QFileInfo(info.path()).lastModified().toSecsSinceEpoch();
        if (!paths.contains(info.id()) || score > scores.value(info.id())) {
            paths.insert(info.id(), info.path());
            scores.insert(info.id(), score);
        }
    }
    return paths;
}

void Browser::syncExtensions() {
    auto *manager = m_profile->extensionManager();
    if (!manager)
        return;
    const auto off = m_settings->value("extensions/disabled").toString().split(',', Qt::SkipEmptyParts);
    const auto preferred = preferredExtensionPaths();
    bool changed = false;
    bool patched = false;
    QSet<QString> seen;
    for (const auto &info : manager->extensions()) {
        if (!info.isInstalled())
            continue;
        // Extra copies of an extension are removed: they would fight the kept
        // one (only one can be on, and the switch would never stay on).
        if (preferred.value(info.id()) != info.path()) {
            if (!m_removing.contains(info.path())) {
                m_removing.insert(info.path());
                if (qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG"))
                    qInfo().noquote() << "[ext dedup] removing" << info.path();
                manager->uninstallExtension(info);
            }
            continue;
        }
        if (!info.isLoaded())
            continue;
        seen.insert(info.id());
        const bool wanted = !off.contains(info.id());
        static const bool trace = qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG");
        if (trace)
            qInfo().noquote() << "[ext sync]" << info.name() << info.id() << info.path() << "enabled" << info.isEnabled() << "wanted" << wanted << info.error();
        if (info.isEnabled() != wanted) {
            manager->setExtensionEnabled(info, wanted);
            changed = true;
        }
        if (m_host) {
            m_host->setExtensionPath(info.id(), info.path());
            patched |= m_host->ensurePatched(info.path());
        }
        if (m_dnr) {
            if (wanted)
                m_dnr->setExtension(info.id(), info.path());
            else
                m_dnr->removeExtension(info.id());
        }
    }
    if (m_dnr)
        for (const auto &id : m_extensionScripts.keys())
            if (!seen.contains(id) || off.contains(id))
                setExtensionScripts(id, {});
    // Ready once every installed extension Qt has on disk is loaded (folders
    // are "<id>_<suffix>"; copies of one id count once).
    QSet<QString> onDisk;
    for (const auto &entry : QDir(manager->installPath()).entryList(QDir::Dirs | QDir::NoDotAndDotDot))
        if (QFile::exists(manager->installPath() + "/" + entry + "/manifest.json"))
            onDisk.insert(entry.section('_', 0, 0));
    if ((seen + m_failedLoads).size() >= onDisk.size())
        setExtensionsReady();
    if (patched && !m_restartNoted) {
        m_restartNoted = true;
        emit extensionMessage("Extensions mises à jour pour Flair Web : redémarre le navigateur pour les activer pleinement.");
    }
    if (changed)
        emit extensionsChanged();
}

// ---------------------------------------------------------------- single instance

// In $XDG_RUNTIME_DIR (this user's alone, 0700), never in the shared /tmp
// where another user could take the name first.
static QString socketName() {
    const auto runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (!runtime.isEmpty())
        return runtime + "/flairweb.sock";
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/flairweb/instance.sock";
}

bool Browser::forwardToRunning(const QStringList &urls, bool privateMode, bool newWindow) {
    QLocalSocket socket;
    socket.connectToServer(socketName());
    if (!socket.waitForConnected(400))
        return false;
    const QJsonObject message{{"urls", QJsonArray::fromStringList(urls)}, {"private", privateMode}, {"window", newWindow}};
    socket.write(QJsonDocument(message).toJson(QJsonDocument::Compact) + "\n");
    socket.flush();
    socket.waitForBytesWritten(1000);
    socket.disconnectFromServer();
    return true;
}

void Browser::listen() {
    // Only called by the process holding the instance lock, so a leftover
    // socket can only come from a crash.
    auto *server = new QLocalServer(this);
    QLocalServer::removeServer(socketName());
    server->setSocketOptions(QLocalServer::UserAccessOption);
    if (!server->listen(socketName()))
        return;
    connect(server, &QLocalServer::newConnection, this, [this, server] {
        while (auto *socket = server->nextPendingConnection()) {
            connect(socket, &QLocalSocket::readyRead, this, [this, socket] {
                if (!socket->canReadLine())
                    return;
                const auto o = QJsonDocument::fromJson(socket->readLine()).object();
                QStringList urls;
                for (const auto &v : o.value("urls").toArray())
                    urls.append(v.toString());
                emit openRequested(urls, o.value("private").toBool(), o.value("window").toBool());
                socket->disconnectFromServer();
            });
            connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
        }
    });
}
