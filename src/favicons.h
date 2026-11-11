#pragma once

#include <QHash>
#include <QObject>
#include <QSet>
#include <QUrl>

class QNetworkAccessManager;

// Site icons for places that are not open in a tab (bookmarks, history,
// shortcuts, suggestions). Each is fetched from the site itself, never from
// a third-party service, and kept as a small PNG in
// ~/.cache/flairweb/favicons/<host>.png.
class Favicons : public QObject {
    Q_OBJECT
    Q_PROPERTY(int revision READ revision NOTIFY changed)

public:
    explicit Favicons(const QString &directory = {}, QObject *parent = nullptr);

    int revision() const { return m_revision; }

    // A file:// URL for the site's icon, or "" while unknown (a fetch of
    // /favicon.ico starts in the background).
    Q_INVOKABLE QString forUrl(const QString &pageUrl);
    // The icon a tab shows for a page: its WebEngineView.icon value
    // ("image://favicon/<icon url>"). Fetched and cached for the site.
    Q_INVOKABLE void remember(const QString &pageUrl, const QString &viewIcon);
    Q_INVOKABLE void clear();
    // The icon a page's HTML declares (<link rel="icon">), public for tests.
    static QUrl iconInPage(const QByteArray &html, const QUrl &base);

signals:
    void changed();

private:
    void fetch(const QString &host, const QUrl &iconUrl, bool fallbackToPage);
    void fetchFromPage(const QString &host, const QUrl &pageUrl);
    QString pathFor(const QString &host) const;

    QString m_directory;
    QNetworkAccessManager *m_network;
    QSet<QString> m_tried;
    QHash<QString, QString> m_rememberedIcon;
    int m_revision = 0;
};
