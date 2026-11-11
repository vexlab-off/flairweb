#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QSettings>
#include <QVariantMap>

// Everything the user can tune in Flair Web, stored in
// ~/.config/flairweb/flairweb.conf (mode 0600: it can hold API keys).
// Values are read through value()/set() so QML can bind to any key, and a
// single changed() signal tells views to re-read.
class BrowserSettings : public QObject {
    Q_OBJECT
    Q_PROPERTY(int revision READ revision NOTIFY changed)

public:
    explicit BrowserSettings(const QString &file = {}, QObject *parent = nullptr);

    int revision() const { return m_revision; }

    Q_INVOKABLE QVariant value(const QString &key) const;
    Q_INVOKABLE void set(const QString &key, const QVariant &value);
    Q_INVOKABLE void reset(const QString &key);
    // Removes every key under a group ("web", "newtab"…), back to defaults.
    Q_INVOKABLE void resetGroup(const QString &group);
    Q_INVOKABLE bool isCustom(const QString &key) const;

    // API key for a provider: the environment wins, then this app's settings,
    // then flair's (so a key entered in flair works here too).
    Q_INVOKABLE QString apiKey(const QString &provider) const;
    Q_INVOKABLE bool keyFromEnvironment(const QString &provider) const;
    static QString environmentVariableFor(const QString &provider);

    static QVariant defaultValue(const QString &key);

    // The suite's shared colours live in flair's settings; while synced,
    // Flair Web reads and writes them there.
    Q_INVOKABLE bool suiteSync() const;
    Q_INVOKABLE void setSuiteSync(bool sync);
    Q_INVOKABLE QString suiteValue(const QString &key, const QString &fallback = {}) const;
    Q_INVOKABLE void setSuiteValue(const QString &key, const QString &value);
    static QString suiteFile();

    // Where downloads go: the setting, or the user's Downloads folder.
    Q_INVOKABLE QString downloadDirectory() const;
    // The User-Agent for a preset ("default" returns empty: Chromium's own).
    Q_INVOKABLE QString userAgent() const;
    static QString userAgentFor(const QString &preset, const QString &custom);

signals:
    void changed();

private:
    QSettings m_settings;
    QFileSystemWatcher m_suiteWatcher;
    int m_revision = 0;
};
