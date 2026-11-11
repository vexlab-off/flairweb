// Flair Web — the web browser of the flair suite.

#include <QStandardPaths>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QFont>
#include <QGuiApplication>
#include <QIcon>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QThread>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QStyleHints>
#include <QSettings>
#include <QTimer>
#include <QUrl>
#include <QSocketNotifier>
#include <csignal>
#include <fcntl.h>
#include <unistd.h>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>

#include "ai.h"
#include "browser.h"
#include "dnr.h"
#include "extensionhost.h"
#include "engines.h"
#include "favicons.h"
#include "launcher.h"
#include "library.h"
#include "pageai.h"
#include "settings.h"
#include "shield.h"
#include "theme.h"

// SIGTERM (a logout, a shutdown), SIGINT, SIGHUP: quit the normal way, so
// the session, history and bookmarks are saved. The handler only writes a
// byte to a pipe; the event loop does the rest.
static int quitPipe[2] = {-1, -1};
static void onQuitSignal(int) {
    const char byte = 1;
    if (quitPipe[1] >= 0)
        (void)!::write(quitPipe[1], &byte, 1);
}
static void quitOnSignals(QObject *rootObject) {
    if (::pipe2(quitPipe, O_CLOEXEC | O_NONBLOCK) != 0)
        return;
    auto *notifier = new QSocketNotifier(quitPipe[0], QSocketNotifier::Read, qApp);
    QObject::connect(notifier, &QSocketNotifier::activated, qApp, [rootObject] {
        char byte;
        while (::read(quitPipe[0], &byte, 1) > 0) {}
        // App.qml's quit(): saves the session, then quits.
        if (!rootObject || !QMetaObject::invokeMethod(rootObject, "quit"))
            QCoreApplication::quit();
    });
    struct sigaction action = {};
    action.sa_handler = onQuitSignal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    for (int sig : {SIGTERM, SIGINT, SIGHUP})
        sigaction(sig, &action, nullptr);
}

// The accent is shared with flair by default: whatever colour flair's
// settings pick, the browser wears too, live. A colour chosen in Flair Web's
// own settings takes over.
static void followAccent(Theme *theme, BrowserSettings *settings, QFileSystemWatcher *watcher) {
    const auto file = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/flair/flair.conf";
    auto apply = [theme, settings, watcher, file] {
        QSettings flair(file, QSettings::IniFormat);
        const bool sync = flair.value("appearance/sync", "true").toString() == "true";
        theme->setLogoStyle(flair.value("appearance/logoStyle", "plein").toString());
        theme->setFolderColor(flair.value("appearance/folderColor", "accent").toString());
        const auto flairAccent = flair.value("appearance/accent", "#ff8a3d").toString();
        const auto flairMode = flair.value("appearance/mode", "auto").toString();
        const auto ownAccent = settings->value("appearance/accent").toString();
        const auto ownMode = settings->value("appearance/mode").toString();
        // A Chrome theme from the Web Store wins while it is installed.
        const auto chrome = QJsonDocument::fromJson(settings->value("appearance/chromeTheme").toString().toUtf8()).object();
        const auto themeAccent = chrome.value("accent").toString();
        const auto themeMode = chrome.value("mode").toString();
        theme->setOverride(!themeAccent.isEmpty() ? themeAccent : sync || ownAccent == "flair" ? flairAccent : ownAccent);
        theme->setMode(!themeMode.isEmpty() ? themeMode : sync || ownMode == "flair" ? flairMode : ownMode);
        if (QFileInfo::exists(file) && !watcher->files().contains(file))
            watcher->addPath(file);
    };
    QObject::connect(watcher, &QFileSystemWatcher::fileChanged, theme, apply);
    QObject::connect(watcher, &QFileSystemWatcher::directoryChanged, theme, apply);
    QObject::connect(settings, &BrowserSettings::changed, theme, apply);
    QDir().mkpath(QFileInfo(file).absolutePath());
    watcher->addPath(QFileInfo(file).absolutePath());
    apply();
}

// FLAIRWEB_STARTUP_LOG=1: how long each step of the start takes (ms since main()).
static void mark(const char *step) { Browser::startupMark(QString::fromLatin1(step)); }

int main(int argc, char *argv[]) {
    Browser::startupClock().start();
    // Chromium wants its flags before the application exists. Smooth
    // scrolling and the GPU are on; the rest are Chromium's defaults.
    QtWebEngineQuick::initialize();
    QGuiApplication app(argc, argv);
    mark("application");
    app.setApplicationName("flairweb");
    app.setApplicationDisplayName("Flair Web");
    app.setApplicationVersion("0.2.0");
    // Matches the window to flairweb.desktop for the compositor and launcher.
    app.setDesktopFileName("flairweb");
    app.setWindowIcon(QIcon::fromTheme("flairweb"));

    // Arguments: addresses or files to open, --private, --new-window.
    QStringList urls;
    bool privateMode = false;
    bool newWindow = false;
    for (const auto &arg : app.arguments().mid(1)) {
        if (arg == "--private" || arg == "-p" || arg == "--incognito")
            privateMode = true;
        else if (arg == "--new-window")
            newWindow = true;
        else if (!arg.startsWith("--"))
            urls.append(QFileInfo::exists(arg) ? QUrl::fromLocalFile(QFileInfo(arg).absoluteFilePath()).toString() : arg);
    }
    const bool snapshotRun = !qEnvironmentVariable("FLAIRWEB_SNAPSHOT").isEmpty();
    // One instance per user: the lock decides who runs; the others hand
    // over their addresses (retrying while the first one starts up).
    const auto dataDir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/flairweb";
    QDir().mkpath(dataDir);
    QLockFile instanceLock(dataDir + "/instance.lock");
    instanceLock.setStaleLockTime(0);
    if (!snapshotRun) {
        if (Browser::forwardToRunning(urls, privateMode, newWindow))
            return 0;
        if (!instanceLock.tryLock(200)) {
            for (int i = 0; i < 40; ++i) {
                if (Browser::forwardToRunning(urls, privateMode, newWindow))
                    return 0;
                QThread::msleep(100);
            }
            qWarning("Flair Web tourne déjà mais ne répond pas.");
            return 1;
        }
    }

    // Compact Material controls, like the rest of the suite.
    qputenv("QT_QUICK_CONTROLS_MATERIAL_VARIANT", "Dense");
    QQuickStyle::setStyle("Material");
    QFont font("Inter");
    font.setPixelSize(13);
    font.setHintingPreference(QFont::PreferNoHinting);
    app.setFont(font);

    Theme theme;
    BrowserSettings settings(qEnvironmentVariable("FLAIRWEB_CONFIG"));
    QFileSystemWatcher accentWatcher;
    followAccent(&theme, &settings, &accentWatcher);
    // Pages see the colour scheme Flair Web wears (prefers-color-scheme),
    // or the one chosen in Contenu web.
    auto applyScheme = [&theme, &settings] {
        const auto choice = settings.value("web/scheme").toString();
        const bool dark = choice == "dark" || (choice != "light" && theme.isDark());
        QGuiApplication::styleHints()->setColorScheme(dark ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light);
    };
    QObject::connect(&theme, &Theme::changed, &app, applyScheme);
    QObject::connect(&settings, &BrowserSettings::changed, &app, applyScheme);
    applyScheme();
    mark("settings and theme");
    Library library(qEnvironmentVariable("FLAIRWEB_DATA"));
    mark("library (history, bookmarks)");
    Favicons favicons;
    SearchEngines engines(&settings);
    Shield shield(&settings);
    mark("engines and shield");
    // Extensions: their network rules and the bridge to the chrome.* APIs.
    // Before Chromium loads the extensions: one folder per extension.
    if (const int moved = Browser::setAsideDuplicateExtensions(dataDir + "/QtWebEngine/flairweb/Extensions", dataDir + "/extensions-duplicates"))
        qInfo("Flair Web : %d copie(s) d'extension en double mise(s) de côté dans %s", moved, qPrintable(dataDir + "/extensions-duplicates"));
    Dnr dnr(dataDir + "/dnr");
    shield.setDnr(&dnr);
    ExtensionHost extensionHost(&dnr, dataDir);
    extensionHost.listen();
    mark("extension rules and host");
    Browser browser(&settings, &shield, urls, privateMode);
    mark("browser profiles");
    browser.setExtensionSupport(&extensionHost, &dnr);
    AiClient ai(&settings);
    PageAi pageAi(&ai, &settings);
    if (!snapshotRun)
        browser.listen();

    // Keep the launcher's Flair Web icon in the suite colour and style, as
    // flair does for the others; only when flair's setting allows it.
    QString lastLauncher;
    auto updateLauncher = [&] {
        QSettings flair(BrowserSettings::suiteFile(), QSettings::IniFormat);
        const bool follow = flair.value("appearance/launcherIcon", "true").toString() == "true";
        const auto key = QString("%1|%2|%3").arg(theme.highlight().name(), theme.logoStyle()).arg(follow);
        if (key == lastLauncher)
            return;
        lastLauncher = key;
        LauncherIcons::apply(theme.highlight(), theme.logoStyle(), follow, QDir::homePath());
    };
    QObject::connect(&theme, &Theme::changed, &app, updateLauncher);
    if (!snapshotRun)
        updateLauncher();

    QQmlApplicationEngine engine;
    auto *context = engine.rootContext();
    context->setContextProperty("theme", &theme);
    context->setContextProperty("settings", &settings);
    context->setContextProperty("library", &library);
    context->setContextProperty("favicons", &favicons);
    context->setContextProperty("engines", &engines);
    context->setContextProperty("shield", &shield);
    context->setContextProperty("browser", &browser);
    context->setContextProperty("extensionHost", &extensionHost);
    context->setContextProperty("pageAi", &pageAi);
    // Development aid: FLAIRWEB_DEV="settings:search" (or panel:history,
    // palette, menu) opens that part of the first window after start.
    context->setContextProperty("devAction", qEnvironmentVariable("FLAIRWEB_DEV"));
    context->setContextProperty("startupLog", qEnvironmentVariableIsSet("FLAIRWEB_STARTUP_LOG"));
    // Milliseconds between two steps of FLAIRWEB_DEV (2500 by default).
    context->setContextProperty("devInterval", qEnvironmentVariableIntValue("FLAIRWEB_DEV_INTERVAL"));
    mark("launcher icons");
    engine.load(QUrl("qrc:/App.qml"));
    mark("QML loaded");
    if (engine.rootObjects().isEmpty())
        return 1;
    quitOnSignals(engine.rootObjects().first());

    QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, [&] {
        if (settings.value("privacy/clearHistoryOnExit").toBool())
            library.clearHistory();
        library.flush();
        browser.shutdown();
    });

    // Development aid: FLAIRWEB_SNAPSHOT=out.png [FLAIRWEB_SNAPSHOT_DELAY=ms]
    // renders the first window to an image and quits.
    if (snapshotRun) {
        const int delay = qEnvironmentVariableIntValue("FLAIRWEB_SNAPSHOT_DELAY");
        QTimer::singleShot(delay > 0 ? delay : 3000, &app, [] {
            const auto snapshot = qEnvironmentVariable("FLAIRWEB_SNAPSHOT");
            // Windows are created from QML without a parent: look at them all.
            for (auto *top : QGuiApplication::topLevelWindows()) {
                auto *window = qobject_cast<QQuickWindow *>(top);
                if (window && window->isVisible()) {
                    window->grabWindow().save(snapshot);
                    break;
                }
            }
            QCoreApplication::quit();
        });
    }
    return app.exec();
}
