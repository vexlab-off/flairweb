#pragma once

#include <QElapsedTimer>
#include <QHash>
#include <QSet>
#include <QObject>
#include <QStringList>
#include <QJsonObject>
#include <QVariantList>
#include <QVariantMap>
#include <atomic>

class BrowserSettings;
class Dnr;
class ExtensionHost;
class QNetworkAccessManager;
class QQuickWebEngineProfile;
class Shield;

// The browser's engine room: the normal and private profiles, kept in step
// with the settings (User-Agent, languages, cookies, downloads, injected
// styles and scripts), Chrome extensions, and the few desktop actions QML
// cannot do alone (clipboard, opening files in flair, default browser).
class Browser : public QObject {
    Q_OBJECT
    Q_PROPERTY(QObject *profile READ profile CONSTANT)
    Q_PROPERTY(QObject *privateProfile READ privateProfile NOTIFY privateProfileChanged)
    Q_PROPERTY(QStringList startUrls READ startUrls CONSTANT)
    Q_PROPERTY(bool startPrivate READ startPrivate CONSTANT)
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QString engineVersion READ engineVersion CONSTANT)
    Q_PROPERTY(QString defaultUserAgent READ defaultUserAgent CONSTANT)
    Q_PROPERTY(QVariantList extensions READ extensions NOTIFY extensionsChanged)
    Q_PROPERTY(bool extensionsSupported READ extensionsSupported CONSTANT)
    Q_PROPERTY(QString extensionsPath READ extensionsPath CONSTANT)
    Q_PROPERTY(bool installing READ installing NOTIFY installingChanged)
    // Installed extensions are loaded and switched on (pages may open).
    Q_PROPERTY(bool extensionsReady READ extensionsReady NOTIFY extensionsReadyChanged)
    Q_PROPERTY(bool hasFlair READ hasFlair CONSTANT)
    Q_PROPERTY(bool traceExtensions READ traceExtensions CONSTANT)

public:
    Browser(BrowserSettings *settings, Shield *shield, const QStringList &startUrls, bool startPrivate,
            QObject *parent = nullptr);

    QObject *profile() const;
    QObject *privateProfile() const;
    QStringList startUrls() const { return m_startUrls; }
    bool startPrivate() const { return m_startPrivate; }
    QString version() const;
    QString engineVersion() const;
    QString defaultUserAgent() const { return m_defaultAgent; }

    // ---- Desktop
    Q_INVOKABLE void copy(const QString &text) const;
    Q_INVOKABLE QString clipboardText() const;
    Q_INVOKABLE void openExternally(const QString &url) const;
    // Opens a file or folder in flair (falls back to the system's handler).
    Q_INVOKABLE void openInFlair(const QString &path) const;
    Q_INVOKABLE void openFile(const QString &path) const;
    Q_INVOKABLE void showInFolder(const QString &path) const;
    bool hasFlair() const;
    bool traceExtensions() const { return qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG"); }
    Q_INVOKABLE bool isDefaultBrowser() const;
    Q_INVOKABLE bool makeDefaultBrowser() const;
    Q_INVOKABLE QString localPath(const QString &url) const;
    Q_INVOKABLE QString fileUrl(const QString &path) const;
    Q_INVOKABLE bool fileExists(const QString &path) const;
    Q_INVOKABLE QString homePath() const;
    // A file in Flair Web's data folder.
    Q_INVOKABLE QString dataPath(const QString &name) const;
    // A file in memory-backed storage ($XDG_RUNTIME_DIR), for pages too big
    // for loadHtml(); returns its file:// URL.
    Q_INVOKABLE QString writeRuntimeFile(const QString &name, const QString &text) const;
    Q_INVOKABLE QString humanSize(double bytes) const;
    Q_INVOKABLE QString uniquePath(const QString &directory, const QString &name) const;
    // Text files for import/export of settings.
    Q_INVOKABLE QString readText(const QString &path) const;
    Q_INVOKABLE bool writeText(const QString &path, const QString &text) const;
    Q_INVOKABLE void launch(const QString &program, const QStringList &arguments) const;

    // ---- Data
    Q_INVOKABLE void clearCookies();
    Q_INVOKABLE void clearCache();
    // Forgets what private tabs left in memory (cookies, cache).
    Q_INVOKABLE void clearPrivateData();

    // ---- Extensions (Chrome, unpacked folder or .zip)
    QVariantList extensions() const;
    bool extensionsSupported() const;
    QString extensionsPath() const;
    Q_INVOKABLE void installExtension(const QString &path);
    Q_INVOKABLE void uninstallExtension(const QString &id);
    Q_INVOKABLE void setExtensionEnabled(const QString &id, bool enabled);
    // From the Chrome Web Store: a store link or a 32-letter extension id.
    // Downloads the .crx from Google's update service and installs it.
    Q_INVOKABLE void installFromStore(const QString &linkOrId);
    // The extension id in a Chrome Web Store link, or "".
    Q_INVOKABLE QString storeExtensionId(const QString &linkOrId) const { return extensionIdIn(linkOrId); }
    static QString extensionIdIn(const QString &linkOrId);
    bool installing() const { return m_installing; }
    bool extensionsReady() const { return m_extensionsReady; }
    // A .crx is a .zip behind a signed header; returns the .zip (or the data
    // unchanged when it already is one, or "" when it is neither).
    static QByteArray crxToZip(const QByteArray &data);
    // The public key a .crx is signed with (its id comes from it), or "".
    static QByteArray crxPublicKey(const QByteArray &data);
    // The extension id for a public key (as Chrome computes it).
    static QString extensionIdForKey(const QByteArray &key);
    // Chromium loads every folder of the install directory: two copies of one
    // extension (an install repeated) knock each other off and it never stays
    // on. Before the profile loads, the extra copies are moved to `asideDir`
    // (kept: the newest copy prepared for Flair Web). Returns how many moved.
    static int setAsideDuplicateExtensions(const QString &installDir, const QString &asideDir);
    // The compatibility layer for extensions (see ExtensionHost).
    void setExtensionSupport(ExtensionHost *host, Dnr *dnr);
    Q_INVOKABLE QString extensionPath(const QString &id) const;
    // A file inside an extension's folder ("" when the name leads outside
    // it, through "..", an absolute path or a symbolic link).
    Q_INVOKABLE QString extensionFile(const QString &id, const QString &relative) const;
    static QString fileInside(const QString &root, const QString &relative);
    Q_INVOKABLE QString readExtensionFile(const QString &id, const QString &relative) const;
    // ---- Chrome themes (a Web Store "extension" with only a theme key):
    // their colours give the accent and the mode, their new tab picture the
    // new tab background. One at a time, in the settings (appearance/chromeTheme).
    Q_INVOKABLE void removeChromeTheme();
    // {accent, mode, ntpColor} from a manifest's "theme" object, public for tests.
    static QVariantMap chromeThemeColors(const QJsonObject &theme);
    // Scripts an extension registered for the page's own world
    // (scripting.registerContentScripts with world MAIN): [{id, js, matches,
    // excludeMatches, runAt, allFrames}].
    Q_INVOKABLE void setExtensionScripts(const QString &id, const QVariantList &scripts);
    Q_INVOKABLE int dnrBlockedOn(const QString &id, const QString &pageUrl) const;
    Q_INVOKABLE bool dnrCountsOnBadge(const QString &id) const;
    Q_INVOKABLE void notify(const QString &title, const QString &message, const QString &icon) const;
    Q_INVOKABLE QString imageDataUrl(const QVariant &image, const QString &format, int quality) const;

    // ---- Injected page styles and scripts, public for tests.
    static QString styleScript(const QString &globalCss, const QString &sitesJson, const QString &cosmeticCss,
                               const QStringList &allowedSites);
    static QString userScript(const QString &globalJs, const QString &sitesJson);
    static QString cosmeticCss();
    static bool sitePatternMatches(const QString &pattern, const QString &host);

    // ---- Development aids for FLAIRWEB_DEV runs: real input events sent to
    // a window (kind: move, press, release, click, double), typed text or a
    // key sequence, and a picture of the window.
    Q_INVOKABLE void devMouse(QObject *window, const QString &kind, qreal x, qreal y, int button = 1) const;
    Q_INVOKABLE void devType(QObject *window, const QString &text) const;
    Q_INVOKABLE void devKey(QObject *window, const QString &sequence) const;
    Q_INVOKABLE bool devGrab(QObject *window, const QString &path) const;

    // FLAIRWEB_STARTUP_LOG=1: ms since main() at each step of the start.
    static QElapsedTimer &startupClock();
    Q_INVOKABLE static void startupMark(const QString &step);

    // What to do on quit (clear data the settings ask to forget).
    void shutdown();

    // One browser per user: a second launch hands its arguments to the
    // running one (over a local socket) and exits.
    static bool forwardToRunning(const QStringList &urls, bool privateMode, bool newWindow);
    void listen();

signals:
    void privateProfileChanged();
    void openRequested(const QStringList &urls, bool privateMode, bool newWindow);
    void extensionsChanged();
    void extensionMessage(const QString &message);
    void installingChanged();
    void extensionsReadyChanged();

private:
    void apply();
    void setUp(QQuickWebEngineProfile *profile);
    void applyScripts(QQuickWebEngineProfile *profile);
    void installZip(const QByteArray &zip, const QString &name, const QByteArray &key = {});
    bool installTheme(const QByteArray &zip, const QString &id);
    void syncExtensions();
    QHash<QString, QString> preferredExtensionPaths() const;
    QSet<QString> m_removing;
    QSet<QString> m_failedLoads;   // folder ids (<id>_<suffix>) Chromium could not load
    QHash<QString, QString> m_installAfterRemoval;   // id -> prepared folder
    void setInstalling(bool on);

    BrowserSettings *m_settings;
    Shield *m_shield;
    QQuickWebEngineProfile *m_profile;
    QQuickWebEngineProfile *m_private;
    QNetworkAccessManager *m_network = nullptr;
    bool m_installing = false;
    ExtensionHost *m_host = nullptr;
    Dnr *m_dnr = nullptr;
    QHash<QString, QVariantList> m_extensionScripts;
    int m_extensionScriptsRevision = 0;
    bool m_restartNoted = false;
    bool m_extensionsReady = false;
    void setExtensionsReady();
    QStringList m_startUrls;
    bool m_startPrivate;
    QString m_defaultAgent;
    QString m_scriptSignature;
    std::atomic<bool> m_blockThirdParty{true};
};
