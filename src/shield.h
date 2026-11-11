#pragma once

#include <QHash>
#include <QObject>
#include <QSet>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QWebEngineUrlRequestInterceptor>
#include <atomic>

class BrowserSettings;
class Dnr;
class QNetworkAccessManager;

// The shield: blocks requests to ad and tracker domains (a built-in list,
// optional downloaded lists, and the user's own), adds Do Not Track and
// Global Privacy Control, and can upgrade http:// to https://. Main-frame
// navigations are never blocked: typing an address always goes there.
// Counts what it blocked per site so the toolbar can show it.
class Shield : public QWebEngineUrlRequestInterceptor {
    Q_OBJECT
    Q_PROPERTY(int revision READ revision NOTIFY changed)
    Q_PROPERTY(int listSize READ listSize NOTIFY changed)
    Q_PROPERTY(QString listUpdated READ listUpdated NOTIFY changed)
    Q_PROPERTY(bool updating READ updating NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(int totalBlocked READ totalBlocked NOTIFY blockedChanged)

public:
    explicit Shield(BrowserSettings *settings, const QString &directory = {}, QObject *parent = nullptr);

    void interceptRequest(QWebEngineUrlRequestInfo &info) override { intercept(info, true); }
    // withExtensions false: private tabs, where extensions' rules don't apply.
    void intercept(QWebEngineUrlRequestInfo &info, bool withExtensions);
    // The interceptor for private tabs: the same shield, without extensions.
    QWebEngineUrlRequestInterceptor *privateInterceptor() { return &m_private; }

    int revision() const { return m_revision; }
    int listSize() const { return m_domains.size(); }
    QString listUpdated() const { return m_listUpdated; }
    bool updating() const { return m_updating > 0; }
    QString status() const { return m_status; }
    int totalBlocked() const { return m_total; }

    // What was blocked on the page shown at `pageUrl` since it last loaded.
    Q_INVOKABLE int blockedOn(const QString &pageUrl) const;
    Q_INVOKABLE QStringList blockedHostsOn(const QString &pageUrl) const;
    Q_INVOKABLE bool isAllowed(const QString &pageUrl) const;
    Q_INVOKABLE void setAllowed(const QString &pageUrl, bool allowed);
    Q_INVOKABLE bool active() const { return m_enabled; }
    // A page upgraded to https failed to load: remember that its site has
    // no working https (for this run) and say so, so it can go back to http.
    Q_INVOKABLE bool upgradeFailed(const QString &url);
    // Downloads the chosen lists (hosts files) and merges them.
    Q_INVOKABLE void updateLists();
    // The lists that can be downloaded: [{key, name, url, enabled}].
    Q_INVOKABLE QVariantList lists() const;
    Q_INVOKABLE void setListEnabled(const QString &key, bool enabled);

    // Would a request to `host` from a page on `firstPartyHost` be blocked?
    bool shouldBlock(const QString &host, const QString &firstPartyHost) const;
    // Extensions' declarativeNetRequest rules, applied before the shield's own.
    void setDnr(Dnr *dnr) { m_dnr = dnr; }

private:
    class PrivateInterceptor : public QWebEngineUrlRequestInterceptor {
    public:
        explicit PrivateInterceptor(Shield *shield) : m_shield(shield) {}
        void interceptRequest(QWebEngineUrlRequestInfo &info) override { m_shield->intercept(info, false); }
    private:
        Shield *m_shield;
    };
    PrivateInterceptor m_private{this};

public:
    static QStringList builtinDomains();
    // Domains from a hosts file ("0.0.0.0 ads.example.com") or a plain list.
    static QStringList parseHostsFile(const QByteArray &bytes);
    static bool isPrivateHost(const QString &host);

signals:
    void changed();
    void blockedChanged();
    // A page's count went up (throttled).
    void blocked(const QString &pageHost);

private:
    void reloadSettings();
    void loadDownloaded();
    QString listPath(const QString &key) const;

    BrowserSettings *m_settings;
    Dnr *m_dnr = nullptr;
    void countBlocked(const QString &firstParty, const QString &host);
    QString m_directory;
    QNetworkAccessManager *m_network;
    QSet<QString> m_domains;
    QSet<QString> m_allowedSites;
    QSet<QString> m_upgradedHosts;
    QSet<QString> m_httpOnlyHosts;
    QHash<QString, QHash<QString, int>> m_blockedBySite;   // site -> blocked host -> count
    QSet<QString> m_pendingNotify;
    QTimer m_notify;
    QString m_signature;
    QString m_listUpdated;
    QString m_status;
    bool m_enabled = true;
    bool m_dnt = true;
    bool m_httpsUpgrade = false;
    int m_updating = 0;
    int m_total = 0;
    int m_revision = 0;
};
