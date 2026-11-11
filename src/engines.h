#pragma once

#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QVariantList>
#include <QVariantMap>

class BrowserSettings;
class QNetworkAccessManager;
class QNetworkReply;

// The search engines: a built-in set (web, AI, and site searches) plus the
// user's own, each with a keyword. Turns what is typed in the address bar
// into an address: a URL as is, "yt chats" searches YouTube, anything else
// goes to the chosen engine. Suggestions come from the engine's OpenSearch
// endpoint when it has one.
class SearchEngines : public QObject {
    Q_OBJECT
    Q_PROPERTY(int revision READ revision NOTIFY changed)

public:
    explicit SearchEngines(BrowserSettings *settings, QObject *parent = nullptr);

    int revision() const { return m_revision; }

    // Every engine, built-in then custom, with overrides applied:
    // {key, name, url, suggest, keyword, color, category, builtin, hidden, home}.
    Q_INVOKABLE QVariantList all(bool includeHidden = false) const;
    Q_INVOKABLE QVariantMap engine(const QString &key) const;
    // The bundled logo for a page of a built-in engine's site (youtube.com,
    // github.com…), "" for other sites.
    Q_INVOKABLE QString logoForUrl(const QString &pageUrl, bool dark) const;
    Q_INVOKABLE QString searchUrl(const QString &key, const QString &query) const;
    // The engine's home page (scheme + host of its search URL).
    Q_INVOKABLE QString homeUrl(const QString &key) const;

    // What the address bar should do with `input`:
    // {kind: "url"|"search", url, engine, query}.
    Q_INVOKABLE QVariantMap resolve(const QString &input, const QString &defaultEngine) const;
    // "yt chats" or "!yt chats": {engine, rest}, or {} when no keyword leads.
    Q_INVOKABLE QVariantMap matchKeyword(const QString &input) const;
    Q_INVOKABLE bool isUrl(const QString &input) const { return looksLikeUrl(input); }
    Q_INVOKABLE QString fixUrl(const QString &input) const { return normalizeUrl(input); }
    static bool looksLikeUrl(const QString &input);
    static QString normalizeUrl(const QString &input);

    // Suggestions for `query` from an engine; answers with suggestionsReady.
    Q_INVOKABLE void suggest(const QString &query, const QString &engineKey);

    // Editing. Overrides change a built-in's keyword, URL or visibility.
    Q_INVOKABLE QString addCustom(const QString &name, const QString &keyword, const QString &url,
                                  const QString &suggestUrl = {});
    Q_INVOKABLE void updateEngine(const QString &key, const QString &name, const QString &keyword, const QString &url,
                                  const QString &suggestUrl);
    Q_INVOKABLE void removeCustom(const QString &key);
    Q_INVOKABLE void setHidden(const QString &key, bool hidden);
    Q_INVOKABLE void resetBuiltin(const QString &key);

    // Parses an OpenSearch suggestion payload (["q", ["a", "b"]]) and a few
    // engine-specific shapes; public for tests.
    static QStringList parseSuggestions(const QByteArray &payload);

signals:
    void changed();
    void suggestionsReady(const QString &query, const QStringList &suggestions);

private:
    QList<QVariantMap> builtins() const;
    QList<QVariantMap> customs() const;
    QJsonObject overrides() const;
    void saveOverrides(const QJsonObject &overrides);
    void saveCustoms(const QList<QVariantMap> &list);

    BrowserSettings *m_settings;
    QNetworkAccessManager *m_network;
    QPointer<QNetworkReply> m_pending;
    int m_revision = 0;
};
