#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariant>
#include <functional>
#include <memory>
#include <vector>

class QWebEngineUrlRequestInfo;

// chrome.declarativeNetRequest, which Qt WebEngine lacks: the rules that
// MV3 ad blockers (uBlock Origin Lite, AdGuard…) ship and add, applied by
// the shield's request interceptor. Static rulesets come from the
// extension's files; dynamic rules are kept on disk, session rules in memory.
class Dnr {
public:
    enum Action : quint8 { Block, Allow, AllowAllRequests, UpgradeScheme, Redirect, ModifyHeaders };
    enum ResourceType : quint8 {
        MainFrame, SubFrame, Stylesheet, Script, Image, Font, Object, XmlHttpRequest, Ping, CspReport,
        Media, WebSocket, WebTransport, WebBundle, Other, TypeCount
    };

    struct Rule {
        int id = 0;
        int priority = 1;
        Action action = Block;
        QString urlFilter;            // lower-cased unless caseSensitive
        bool caseSensitive = false;
        QString regexFilter;
        std::shared_ptr<QRegularExpression> regex; // compiled on first use
        QStringList requestDomains, excludedRequestDomains, initiatorDomains, excludedInitiatorDomains;
        quint32 resourceTypes = 0;    // 0: every type but main_frame
        quint32 excludedResourceTypes = 0;
        QStringList requestMethods, excludedRequestMethods;
        quint8 domainType = 0;        // 0 any, 1 first party, 2 third party
        QJsonObject redirect;
        QJsonArray requestHeaders;
        int set = -1;                 // index into m_sets
    };

    // What a request should do.
    struct Outcome {
        bool matched = false;
        bool block = false;
        QUrl redirect;
        QList<QPair<QByteArray, QByteArray>> headers;
        QString extension;
        int ruleId = 0;
        QString rulesetId;
    };

    explicit Dnr(const QString &directory);
    // Where a redirect to one of an extension's files goes (Qt WebEngine
    // doesn't serve extensions' web-accessible files to pages).
    void setFileUrl(std::function<QUrl(const QString &, const QString &)> provider) { m_fileUrl = std::move(provider); }

    // An enabled extension (its folder holds the manifest and the rule files).
    void setExtension(const QString &id, const QString &path);
    void removeExtension(const QString &id);
    bool hasExtension(const QString &id) const { return m_extensions.contains(id); }

    // The interceptor's question, for one request.
    Outcome evaluate(const QUrl &url, const QUrl &initiator, const QUrl &firstParty, int resourceType,
                     const QByteArray &method);
    // Applies an outcome to the request; true when it stopped or moved it.
    static bool apply(const Outcome &outcome, QWebEngineUrlRequestInfo &info);
    static int typeOf(int qtResourceType);

    // chrome.declarativeNetRequest.<method>(args) for an extension.
    QVariant call(const QString &extension, const QString &method, const QVariantList &args, QString *error);

    // Requests an extension's rules blocked on a page (for its badge).
    int blockedOn(const QString &extension, const QString &pageUrl) const;

    // ---- exposed for tests
    static bool matchUrlFilter(const QString &filter, const QString &url, int hostStart, int hostEnd);
    static Rule parseRule(const QJsonObject &object, QString *error = nullptr);
    static QJsonObject ruleToJson(const Rule &rule);
    int ruleCount() const;

private:
    struct RuleSet {
        QString extension;
        QString id;               // static ruleset id, "_dynamic" or "_session"
        std::vector<Rule> rules;
        QSet<int> disabled;       // static rule ids switched off
    };
    struct Extension {
        QString path;
        QJsonArray resources;     // manifest rule_resources
        QStringList enabled;      // enabled static ruleset ids
        QHash<QString, QSet<int>> disabledStatic;
        QJsonArray dynamicRules, sessionRules;
        bool actionCountBadge = false;
    };

    void loadState(const QString &id, Extension &ext);
    void saveState(const QString &id) const;
    void rebuild();
    bool ruleMatches(Rule &rule, const QString &url, const QString &lowerUrl, int hostStart, int hostEnd,
                     const QString &host, const QString &initiatorHost, bool thirdParty, int type,
                     const QString &method) const;
    static QString tokenFor(const QString &filter);
    static bool hostMatches(const QString &host, const QStringList &domains);
    QUrl redirectFor(const Rule &rule, const QUrl &url) const;

    QString m_directory;
    std::function<QUrl(const QString &, const QString &)> m_fileUrl;
    QHash<QString, Extension> m_extensions;
    std::vector<std::unique_ptr<RuleSet>> m_sets;
    // Index: rules by domain (from "||host^" or requestDomains), by a token
    // of their filter, and the rest.
    QHash<QString, std::vector<Rule *>> m_byDomain;
    QHash<QString, std::vector<Rule *>> m_byToken;
    std::vector<Rule *> m_generic;
    // Pages (first-party URL) under an allowAllRequests rule, with its priority.
    QHash<QString, int> m_allowAllPages;
    // ext -> site -> count
    QHash<QString, QHash<QString, int>> m_blocked;
};
