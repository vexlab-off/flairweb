#include "settings.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QStandardPaths>

BrowserSettings::BrowserSettings(const QString &file, QObject *parent)
    : QObject(parent),
      m_settings(file.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/flairweb/flairweb.conf" : file, QSettings::IniFormat) {
    // flair may change the suite's colours at any time; views re-read them.
    const auto suite = suiteFile();
    QDir().mkpath(QFileInfo(suite).absolutePath());
    m_suiteWatcher.addPath(QFileInfo(suite).absolutePath());
    if (QFileInfo::exists(suite))
        m_suiteWatcher.addPath(suite);
    auto bump = [this, suite] {
        if (QFileInfo::exists(suite) && !m_suiteWatcher.files().contains(suite))
            m_suiteWatcher.addPath(suite);
        ++m_revision;
        emit changed();
    };
    connect(&m_suiteWatcher, &QFileSystemWatcher::fileChanged, this, bump);
    connect(&m_suiteWatcher, &QFileSystemWatcher::directoryChanged, this, bump);
}

QString BrowserSettings::suiteFile() { return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/flair/flair.conf"; }

QString BrowserSettings::suiteValue(const QString &key, const QString &fallback) const {
    QSettings suite(suiteFile(), QSettings::IniFormat);
    const auto value = suite.value(key).toString().trimmed();
    return value.isEmpty() ? fallback : value;
}

void BrowserSettings::setSuiteValue(const QString &key, const QString &value) {
    QSettings suite(suiteFile(), QSettings::IniFormat);
    suite.setValue(key, value);
    suite.sync();
    QFile::setPermissions(suite.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    ++m_revision;
    emit changed();
}

bool BrowserSettings::suiteSync() const { return suiteValue("appearance/sync", "true") == "true"; }
void BrowserSettings::setSuiteSync(bool sync) { setSuiteValue("appearance/sync", sync ? "true" : "false"); }

QVariant BrowserSettings::defaultValue(const QString &key) {
    static const QHash<QString, QVariant> defaults{
        // Appearance
        {"appearance/accent", "flair"}, // "flair" follows flair's accent, else #rrggbb
        {"appearance/mode", "flair"},   // "flair", "auto", "light" or "dark"
        {"appearance/density", "comfortable"}, // or "compact"
        {"appearance/pageCard", true},  // the page floats in a card with a margin
        {"appearance/radius", 10},      // corner radius of the card and panels
        {"appearance/uiScale", 1.0},
        // A Chrome theme from the Web Store: {id, name, accent, mode, ntpColor, image} as JSON, "" for none.
        {"appearance/chromeTheme", ""},
        // Tabs
        {"tabs/position", "side"},      // "side" (vertical) or "top"
        {"tabs/sideWidth", 248},
        {"tabs/compact", false},        // vertical tabs as icons only
        {"tabs/newTabPosition", "afterCurrent"}, // or "end"
        {"tabs/backgroundLinks", true}, // middle-click / new-window links open behind
        {"tabs/sleepMinutes", 30},      // 0 never puts tabs to sleep
        {"tabs/confirmCloseMany", true},
        {"tabs/closeButton", "hover"},  // "hover", "always", "never"
        {"tabs/closeWindowWithLastTab", false},
        // Toolbar
        {"toolbar/bookmarksBar", "newtab"}, // "always", "newtab", "never"
        {"toolbar/home", false},
        {"toolbar/ai", true},
        {"toolbar/library", true},
        {"toolbar/downloads", true},
        {"toolbar/shield", true},
        {"toolbar/reader", true},
        {"toolbar/linkPreview", true},
        {"toolbar/fullUrl", false},     // show the whole address, not just the site
        {"toolbar/devtools", false},
        {"toolbar/extensions", true},
        {"toolbar/settings", true},
        {"toolbar/extensionIcons", true}, // each extension's button
        {"extensions/disabled", ""},    // ids of installed extensions switched off
        {"toolbar/engineButton", true}, // engine chooser at the left of the address
        // Search
        {"search/engine", "duckduckgo"},
        {"search/privateEngine", "duckduckgo"},
        {"search/suggestions", true},
        {"search/privateSuggestions", false},
        {"search/historySuggestions", true},
        {"search/bookmarkSuggestions", true},
        {"search/maxSuggestions", 8},
        {"search/keywords", "space"},   // "space" (yt chats), "bang" (!yt chats only), "off"
        {"search/newTab", false},       // open searches from the address bar in a new tab
        {"search/chosen", false},       // the first-run engine chooser was answered
        {"search/custom", "[]"},        // JSON [{key,name,url,suggest,keyword,color}]
        {"search/overrides", "{}"},     // JSON {key: {keyword, url, hidden}}
        // Start
        {"start/mode", "session"},      // "session", "newtab" or "home"
        {"start/home", ""},
        // New tab page
        {"newtab/background", "glow"},  // "glow", "plain", "gradient", "image"
        {"newtab/image", ""},
        {"newtab/dim", 0.35},
        {"newtab/clock", true},
        {"newtab/seconds", false},
        {"newtab/greeting", true},
        {"newtab/name", ""},
        {"newtab/search", true},
        {"newtab/engines", true},
        {"newtab/shortcuts", true},
        {"newtab/columns", 6},
        {"newtab/recent", true},
        {"newtab/engineKeys", "duckduckgo,google,claude,perplexity,wikipedia,youtube,github"},
        {"newtab/tiles", "rounded"},    // "rounded", "circle", "square"
        // Privacy
        {"privacy/shield", true},       // block ads and trackers
        {"privacy/cosmetic", true},     // hide the empty ad slots left behind
        {"privacy/dnt", true},          // Do Not Track + Global Privacy Control
        {"privacy/httpsUpgrade", false},
        {"privacy/thirdPartyCookies", false},
        {"privacy/cookies", "persistent"}, // "persistent", "session"
        {"privacy/history", true},
        {"privacy/clearHistoryOnExit", false},
        {"privacy/clearCookiesOnExit", false},
        {"privacy/clearCacheOnExit", false},
        {"privacy/blocked", ""},        // extra domains to block, one per line
        {"privacy/allowed", ""},        // sites where the shield stays down
        {"privacy/permissions", "ask"}, // "ask", "deny"
        // Web content
        {"web/javascript", true},
        {"web/images", true},
        {"web/forceDark", false},
        {"web/scheme", "flair"},        // what pages see: "flair" (the app's mode), "light", "dark"
        {"web/autoplay", false},
        {"web/zoom", 1.0},
        {"web/smoothScroll", true},
        {"web/pdf", true},
        {"web/webgl", true},
        {"web/scrollbars", true},
        {"web/spatialNavigation", false},
        {"web/dnsPrefetch", true},
        {"web/clipboard", false},
        {"web/userAgent", "default"},   // "default", "firefox", "chrome", "safari", "mobile", "custom"
        {"web/customAgent", ""},
        {"web/language", "fr-FR,fr;q=0.9,en-US;q=0.6,en;q=0.5"},
        // Styles and scripts
        {"style/css", ""},
        {"style/js", ""},
        {"style/sites", "[]"},          // JSON [{pattern, css, js, enabled}]
        // Reading mode
        {"reader/font", "serif"},
        {"reader/size", 19},
        {"reader/width", 700},
        {"reader/theme", "auto"},
        // Downloads
        {"downloads/dir", ""},
        {"downloads/openPanel", true},
        {"downloads/after", "nothing"}, // "nothing", "open" (the file), "folder" (in flair)
        // AI
        {"ai/provider", "claude"},
        {"ai/claudeModel", "claude-opus-5-5"},
        {"ai/openaiModel", ""},
        {"ai/geminiModel", ""},
        {"ai/localUrl", "http://localhost:1234"},
        {"ai/localModel", ""},
        {"ai/language", "fr"},
        {"ai/pageChars", 60000},
    };
    return defaults.value(key);
}

QVariant BrowserSettings::value(const QString &key) const {
    const auto stored = m_settings.value(key);
    if (!stored.isValid())
        return defaultValue(key);
    // INI stores everything as text; give QML back the type of the default.
    const auto fallback = defaultValue(key);
    switch (fallback.typeId()) {
    case QMetaType::Bool:
        return stored.toString() == "true" || stored.toString() == "1";
    case QMetaType::Int:
        return stored.toInt();
    case QMetaType::Double:
        return stored.toDouble();
    default:
        return stored;
    }
}

void BrowserSettings::set(const QString &key, const QVariant &value) {
    if (m_settings.contains(key) ? m_settings.value(key).toString() == value.toString() : value == defaultValue(key))
        return;
    // Storing the default keeps the file tidy and lets defaults improve later.
    const auto fallback = defaultValue(key);
    if (fallback.isValid() && value.toString() == fallback.toString())
        m_settings.remove(key);
    else
        m_settings.setValue(key, value);
    m_settings.sync();
    QFile::setPermissions(m_settings.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    ++m_revision;
    emit changed();
}

void BrowserSettings::reset(const QString &key) {
    if (!m_settings.contains(key))
        return;
    m_settings.remove(key);
    m_settings.sync();
    ++m_revision;
    emit changed();
}

void BrowserSettings::resetGroup(const QString &group) {
    m_settings.beginGroup(group);
    m_settings.remove("");
    m_settings.endGroup();
    m_settings.sync();
    ++m_revision;
    emit changed();
}

bool BrowserSettings::isCustom(const QString &key) const { return m_settings.contains(key); }

QString BrowserSettings::environmentVariableFor(const QString &provider) {
    if (provider == "claude")
        return "ANTHROPIC_API_KEY";
    if (provider == "openai")
        return "OPENAI_API_KEY";
    if (provider == "gemini")
        return "GEMINI_API_KEY";
    return {};
}

bool BrowserSettings::keyFromEnvironment(const QString &provider) const {
    const auto variable = environmentVariableFor(provider);
    return !variable.isEmpty() && !qEnvironmentVariable(variable.toUtf8()).trimmed().isEmpty();
}

QString BrowserSettings::apiKey(const QString &provider) const {
    const auto variable = environmentVariableFor(provider);
    if (variable.isEmpty())
        return {};
    const auto env = qEnvironmentVariable(variable.toUtf8()).trimmed();
    if (!env.isEmpty())
        return env;
    if (provider == "gemini") {
        const auto google = qEnvironmentVariable("GOOGLE_API_KEY").trimmed();
        if (!google.isEmpty())
            return google;
    }
    const auto own = m_settings.value("keys/" + provider).toString().trimmed();
    if (!own.isEmpty())
        return own;
    // Keys entered in flair or Flair Code work here too.
    if (provider == "claude") {
        QSettings flair(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/flair/flair.conf", QSettings::IniFormat);
        const auto key = flair.value("claude/apiKey").toString().trimmed();
        if (!key.isEmpty())
            return key;
    }
    QSettings code(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/flaircode/flaircode.conf", QSettings::IniFormat);
    return code.value("keys/" + provider).toString().trimmed();
}

QString BrowserSettings::downloadDirectory() const {
    const auto chosen = value("downloads/dir").toString().trimmed();
    if (!chosen.isEmpty())
        return chosen.startsWith("~/") ? QDir::homePath() + chosen.mid(1) : chosen;
    const auto standard = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    return standard.isEmpty() ? QDir::homePath() : standard;
}

QString BrowserSettings::userAgent() const {
    return userAgentFor(value("web/userAgent").toString(), value("web/customAgent").toString());
}

QString BrowserSettings::userAgentFor(const QString &preset, const QString &custom) {
    if (preset == "firefox")
        return "Mozilla/5.0 (X11; Linux x86_64; rv:145.0) Gecko/20100101 Firefox/145.0";
    if (preset == "chrome")
        return "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36";
    if (preset == "safari")
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";
    if (preset == "mobile")
        return "Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36";
    if (preset == "custom")
        return custom.trimmed();
    return {};
}
