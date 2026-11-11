#include "engines.h"

#include "settings.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>

SearchEngines::SearchEngines(BrowserSettings *settings, QObject *parent)
    : QObject(parent), m_settings(settings), m_network(new QNetworkAccessManager(this)) {
    connect(m_settings, &BrowserSettings::changed, this, [this] {
        ++m_revision;
        emit changed();
    });
}

static QVariantMap make(const QString &key, const QString &name, const QString &url, const QString &suggest,
                        const QString &keyword, const QString &color, const QString &category) {
    return {{"key", key},         {"name", name},   {"url", url},           {"suggest", suggest},
            {"keyword", keyword}, {"color", color}, {"category", category}, {"builtin", true}};
}

QList<QVariantMap> SearchEngines::builtins() const {
    // Brand colours, behind the logos (src/logos/<key>.png) and for engines without one.
    static const QList<QVariantMap> list{
        // The web
        make("duckduckgo", "DuckDuckGo", "https://duckduckgo.com/?q=%s", "https://duckduckgo.com/ac/?q=%s&type=list",
             "ddg", "#de5833", "web"),
        make("google", "Google", "https://www.google.com/search?q=%s",
             "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=%s", "gg", "#4285f4",
             "web"),
        make("brave", "Brave Search", "https://search.brave.com/search?q=%s", "https://search.brave.com/api/suggest?q=%s",
             "brave", "#fb542b", "web"),
        make("startpage", "Startpage", "https://www.startpage.com/sp/search?query=%s",
             "https://www.startpage.com/osuggestions?q=%s", "sp", "#6573ff", "web"),
        make("qwant", "Qwant", "https://www.qwant.com/?q=%s", "https://api.qwant.com/v3/suggest?q=%s&locale=fr_FR", "qw",
             "#5c97ff", "web"),
        make("ecosia", "Ecosia", "https://www.ecosia.org/search?q=%s", "https://ac.ecosia.org/autocomplete?q=%s&type=list",
             "eco", "#36acb8", "web"),
        make("bing", "Bing", "https://www.bing.com/search?q=%s", "https://api.bing.com/osjson.aspx?query=%s", "bing",
             "#2b8fd6", "web"),
        make("kagi", "Kagi", "https://kagi.com/search?q=%s", "", "kagi", "#ffb319", "web"),
        make("mojeek", "Mojeek", "https://www.mojeek.com/search?q=%s", "", "mj", "#7ab93d", "web"),
        make("searxng", "SearXNG", "https://searx.be/search?q=%s", "", "sx", "#3050ff", "web"),
        // Answer engines
        make("claude", "Claude", "https://claude.ai/new?q=%s", "", "cl", "#d97757", "ia"),
        make("perplexity", "Perplexity", "https://www.perplexity.ai/search?q=%s", "", "px", "#20808d", "ia"),
        make("chatgpt", "ChatGPT", "https://chatgpt.com/?q=%s", "", "gpt", "#10a37f", "ia"),
        // Sites
        make("wikipedia", "Wikipédia", "https://fr.wikipedia.org/w/index.php?search=%s",
             "https://fr.wikipedia.org/w/api.php?action=opensearch&format=json&search=%s", "wiki", "#a2a9b1", "site"),
        make("youtube", "YouTube", "https://www.youtube.com/results?search_query=%s",
             "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q=%s", "yt", "#ff0033", "site"),
        make("github", "GitHub", "https://github.com/search?q=%s&type=repositories", "", "gh", "#8b949e", "site"),
        make("archwiki", "ArchWiki", "https://wiki.archlinux.org/index.php?search=%s", "", "aw", "#1793d1", "site"),
        make("aur", "AUR", "https://aur.archlinux.org/packages?K=%s", "", "aur", "#1793d1", "site"),
        make("mdn", "MDN", "https://developer.mozilla.org/fr/search?q=%s", "", "mdn", "#83d0f2", "site"),
        make("stackoverflow", "Stack Overflow", "https://stackoverflow.com/search?q=%s", "", "sof", "#f48024", "site"),
        make("reddit", "Reddit", "https://www.reddit.com/search/?q=%s", "", "rd", "#ff4500", "site"),
        make("osm", "OpenStreetMap", "https://www.openstreetmap.org/search?query=%s", "", "osm", "#7ebc6f", "site"),
        make("deepl", "DeepL", "https://www.deepl.com/translator#auto/fr/%s", "", "tr", "#0f2b46", "site"),
        make("wordreference", "WordReference", "https://www.wordreference.com/fren/%s", "", "wr", "#3d7dca", "site"),
        make("imdb", "IMDb", "https://www.imdb.com/find/?q=%s", "", "imdb", "#f5c518", "site"),
    };
    return list;
}

QJsonObject SearchEngines::overrides() const {
    return QJsonDocument::fromJson(m_settings->value("search/overrides").toString().toUtf8()).object();
}

void SearchEngines::saveOverrides(const QJsonObject &overrides) {
    m_settings->set("search/overrides", QString::fromUtf8(QJsonDocument(overrides).toJson(QJsonDocument::Compact)));
}

QList<QVariantMap> SearchEngines::customs() const {
    QList<QVariantMap> list;
    const auto array = QJsonDocument::fromJson(m_settings->value("search/custom").toString().toUtf8()).array();
    for (const auto &item : array) {
        auto map = item.toObject().toVariantMap();
        if (map.value("key").toString().isEmpty() || map.value("url").toString().isEmpty())
            continue;
        map["builtin"] = false;
        map["category"] = "custom";
        if (map.value("color").toString().isEmpty())
            map["color"] = "#8a8f98";
        list.append(map);
    }
    return list;
}

void SearchEngines::saveCustoms(const QList<QVariantMap> &list) {
    QJsonArray array;
    for (auto map : list) {
        map.remove("builtin");
        map.remove("category");
        map.remove("hidden");
        map.remove("home");
        array.append(QJsonObject::fromVariantMap(map));
    }
    m_settings->set("search/custom", QString::fromUtf8(QJsonDocument(array).toJson(QJsonDocument::Compact)));
}

QVariantList SearchEngines::all(bool includeHidden) const {
    QVariantList out;
    const auto over = overrides();
    for (auto map : builtins()) {
        const auto o = over.value(map.value("key").toString()).toObject();
        for (const auto field : {"name", "keyword", "url", "suggest"})
            if (o.contains(field))
                map[field] = o.value(field).toString();
        map["hidden"] = o.value("hidden").toBool();
        map["custom"] = !o.isEmpty() && (o.contains("keyword") || o.contains("url") || o.contains("name") ||
                                         o.contains("suggest"));
        if (map["hidden"].toBool() && !includeHidden)
            continue;
        map["home"] = homeUrl(map.value("url").toString());
        // The engine's own logo, bundled (a white one for dark backgrounds
        // when the logo is black).
        const auto key = map.value("key").toString();
        if (QFile::exists(":/logos/" + key + ".png")) {
            map["logo"] = "qrc:/logos/" + key + ".png";
            map["logoDark"] = QFile::exists(":/logos/" + key + "-dark.png") ? "qrc:/logos/" + key + "-dark.png" : map["logo"];
        }
        out.append(map);
    }
    for (auto map : customs()) {
        map["hidden"] = false;
        map["home"] = homeUrl(map.value("url").toString());
        out.append(map);
    }
    return out;
}

QString SearchEngines::logoForUrl(const QString &pageUrl, bool dark) const {
    // The bundled logo of a built-in engine whose site this is.
    const auto host = QUrl(pageUrl).host().toLower().remove(QRegularExpression("^www\\."));
    if (host.isEmpty())
        return {};
    for (const auto &e : builtins()) {
        const auto key = e.value("key").toString();
        const auto engineHost = QUrl(e.value("url").toString().replace("%s", "")).host().toLower().remove(QRegularExpression("^www\\."));
        if (engineHost != host || !QFile::exists(":/logos/" + key + ".png"))
            continue;
        if (dark && QFile::exists(":/logos/" + key + "-dark.png"))
            return "qrc:/logos/" + key + "-dark.png";
        return "qrc:/logos/" + key + ".png";
    }
    return {};
}

QVariantMap SearchEngines::engine(const QString &key) const {
    const auto list = all(true);
    for (const auto &e : list)
        if (e.toMap().value("key").toString() == key)
            return e.toMap();
    // Unknown keys fall back to the first engine, so a search always goes somewhere.
    return list.isEmpty() ? QVariantMap{} : list.first().toMap();
}

QString SearchEngines::searchUrl(const QString &key, const QString &query) const {
    auto url = engine(key).value("url").toString();
    const auto encoded = QString::fromUtf8(QUrl::toPercentEncoding(query.trimmed()));
    if (url.contains("%s"))
        return url.replace("%s", encoded);
    return url + encoded;
}

QString SearchEngines::homeUrl(const QString &keyOrUrl) const {
    const auto template_ = keyOrUrl.contains("://") ? keyOrUrl : engine(keyOrUrl).value("url").toString();
    const QUrl url(QString(template_).replace("%s", ""));
    if (!url.isValid() || url.host().isEmpty())
        return {};
    return url.scheme() + "://" + url.host() + "/";
}

QVariantMap SearchEngines::matchKeyword(const QString &rawInput) const {
    const auto mode = m_settings->value("search/keywords").toString();
    if (mode == "off")
        return {};
    const auto input = rawInput.trimmed() + (rawInput.endsWith(' ') ? " " : "");
    // "!kw rest", "rest !kw" (DuckDuckGo bangs) or "kw rest".
    static const QRegularExpression bangFirst(R"(^!(\S+)(?:\s+(.*))?$)", QRegularExpression::DotMatchesEverythingOption);
    static const QRegularExpression bangLast(R"(^(.*\S)\s+!(\S+)$)", QRegularExpression::DotMatchesEverythingOption);
    static const QRegularExpression plain(R"(^(\S+)\s+(.*)$)", QRegularExpression::DotMatchesEverythingOption);
    QString keyword, rest;
    bool bang = false;
    if (auto m = bangFirst.match(input); m.hasMatch()) {
        keyword = m.captured(1);
        rest = m.captured(2);
        bang = true;
    } else if (auto m2 = bangLast.match(input); m2.hasMatch()) {
        keyword = m2.captured(2);
        rest = m2.captured(1);
        bang = true;
    } else if (auto m3 = plain.match(input); m3.hasMatch() && mode != "bang") {
        keyword = m3.captured(1);
        rest = m3.captured(2);
    }
    if (keyword.isEmpty())
        return {};
    for (const auto &e : all()) {
        const auto map = e.toMap();
        const auto kw = map.value("keyword").toString();
        if (!kw.isEmpty() && kw.compare(keyword, Qt::CaseInsensitive) == 0)
            return {{"engine", map.value("key")}, {"name", map.value("name")}, {"rest", rest.trimmed()},
                    {"keyword", kw}, {"bang", bang}, {"color", map.value("color")}};
    }
    return {};
}

bool SearchEngines::looksLikeUrl(const QString &raw) {
    const auto input = raw.trimmed();
    if (input.isEmpty())
        return false;
    static const QRegularExpression scheme(
        R"(^(https?|file|ftp|about|chrome|view-source|data|mailto|blob|qrc|flair|chrome-extension):)",
        QRegularExpression::CaseInsensitiveOption);
    if (scheme.match(input).hasMatch())
        return !input.startsWith("about:") || !input.contains(' ');
    if (input.contains(QRegularExpression(R"(\s)")))
        return false;
    if (input.startsWith('/') || input.startsWith("~/"))
        return true;
    static const QRegularExpression localhost(R"(^localhost(:\d+)?([/?#].*)?$)", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression ipv4(R"(^\d{1,3}(\.\d{1,3}){3}(:\d+)?([/?#].*)?$)");
    static const QRegularExpression ipv6(R"(^\[[0-9a-fA-F:]+\](:\d+)?([/?#].*)?$)");
    static const QRegularExpression host(R"(^([a-z0-9\-_]+@)?([a-z0-9\x{00a0}-\x{ffff}]([a-z0-9\-\x{00a0}-\x{ffff}]*[a-z0-9\x{00a0}-\x{ffff}])?\.)+([a-z\x{00a0}-\x{ffff}]{2,63}|xn--[a-z0-9\-]+)\.?(:\d+)?([/?#].*)?$)",
                                         QRegularExpression::CaseInsensitiveOption);
    return localhost.match(input).hasMatch() || ipv4.match(input).hasMatch() || ipv6.match(input).hasMatch() ||
           host.match(input).hasMatch();
}

QString SearchEngines::normalizeUrl(const QString &raw) {
    const auto input = raw.trimmed();
    static const QRegularExpression scheme(R"(^[a-zA-Z][a-zA-Z0-9+.\-]*:)");
    static const QRegularExpression local(R"(^(localhost|\d{1,3}(\.\d{1,3}){3}|\[[0-9a-fA-F:]+\])(:\d+)?([/?#].*)?$)",
                                          QRegularExpression::CaseInsensitiveOption);
    if (input.startsWith("~/"))
        return QUrl::fromLocalFile(QDir::homePath() + input.mid(1)).toString(QUrl::FullyEncoded);
    if (input.startsWith('/'))
        return QUrl::fromLocalFile(input).toString(QUrl::FullyEncoded);
    if (local.match(input).hasMatch())
        return "http://" + input;
    // "user@host" is not a scheme, but "mailto:x" and "localhost:8080" are handled above.
    if (scheme.match(input).hasMatch() && !input.contains(QRegularExpression(R"(^[^:/]+:\d)")))
        return input;
    return "https://" + input;
}

QVariantMap SearchEngines::resolve(const QString &input, const QString &defaultEngine) const {
    const auto text = input.trimmed();
    if (text.isEmpty())
        return {};
    const auto keyword = matchKeyword(input);
    if (!keyword.isEmpty()) {
        const auto key = keyword.value("engine").toString();
        const auto rest = keyword.value("rest").toString();
        if (rest.isEmpty())
            return {{"kind", "url"}, {"url", homeUrl(key)}, {"engine", key}, {"query", ""}};
        return {{"kind", "search"}, {"url", searchUrl(key, rest)}, {"engine", key}, {"query", rest}};
    }
    if (looksLikeUrl(text))
        return {{"kind", "url"}, {"url", normalizeUrl(text)}, {"engine", ""}, {"query", ""}};
    const auto key = engine(defaultEngine).value("key").toString();
    return {{"kind", "search"}, {"url", searchUrl(key, text)}, {"engine", key}, {"query", text}};
}

QStringList SearchEngines::parseSuggestions(const QByteArray &payload) {
    QStringList out;
    const auto doc = QJsonDocument::fromJson(payload);
    if (doc.isArray()) {
        const auto array = doc.array();
        // OpenSearch: ["query", ["a", "b", …], …]
        if (array.size() >= 2 && array.at(1).isArray()) {
            for (const auto &v : array.at(1).toArray())
                if (v.isString())
                    out.append(v.toString());
        } else {
            // DuckDuckGo's other shape: [{"phrase": "a"}, …]
            for (const auto &v : array)
                if (v.isObject() && v.toObject().contains("phrase"))
                    out.append(v.toObject().value("phrase").toString());
        }
    } else if (doc.isObject()) {
        // Qwant: {"data": {"items": [{"value": "a"}]}}
        const auto items = doc.object().value("data").toObject().value("items").toArray();
        for (const auto &v : items)
            out.append(v.toObject().value("value").toString());
    }
    out.removeAll(QString());
    out.removeDuplicates();
    return out;
}

void SearchEngines::suggest(const QString &query, const QString &engineKey) {
    if (m_pending)
        m_pending->abort();
    const auto trimmed = query.trimmed();
    auto suggestUrl = engine(engineKey).value("suggest").toString();
    if (trimmed.isEmpty() || suggestUrl.isEmpty()) {
        emit suggestionsReady(query, {});
        return;
    }
    const QUrl url(suggestUrl.replace("%s", QString::fromUtf8(QUrl::toPercentEncoding(trimmed))));
    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::UserAgentHeader, "Mozilla/5.0 (X11; Linux x86_64) FlairWeb/0.1");
    request.setTransferTimeout(4000);
    auto *reply = m_network->get(request);
    m_pending = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply, query] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError)
            return;
        emit suggestionsReady(query, parseSuggestions(reply->readAll()).mid(0, 10));
    });
}

QString SearchEngines::addCustom(const QString &name, const QString &keyword, const QString &url, const QString &suggestUrl) {
    if (name.trimmed().isEmpty() || url.trimmed().isEmpty())
        return {};
    auto list = customs();
    const auto key = "custom-" + QString::number(QDateTime::currentMSecsSinceEpoch(), 36);
    static const QStringList palette{"#ff8a3d", "#9b7bff", "#3ecf8e", "#5c9df5", "#ec5fa6", "#4fd6c4", "#f5b942"};
    list.append({{"key", key},
                 {"name", name.trimmed()},
                 {"keyword", keyword.trimmed()},
                 {"url", url.trimmed()},
                 {"suggest", suggestUrl.trimmed()},
                 {"color", palette.at(list.size() % palette.size())}});
    saveCustoms(list);
    return key;
}

void SearchEngines::updateEngine(const QString &key, const QString &name, const QString &keyword, const QString &url,
                                 const QString &suggestUrl) {
    auto list = customs();
    for (auto &map : list) {
        if (map.value("key").toString() != key)
            continue;
        map["name"] = name.trimmed().isEmpty() ? map.value("name") : name.trimmed();
        map["keyword"] = keyword.trimmed();
        map["url"] = url.trimmed().isEmpty() ? map.value("url") : url.trimmed();
        map["suggest"] = suggestUrl.trimmed();
        saveCustoms(list);
        return;
    }
    // A built-in: store only what differs from the original.
    for (const auto &original : builtins()) {
        if (original.value("key").toString() != key)
            continue;
        auto over = overrides();
        auto o = over.value(key).toObject();
        auto store = [&o, &original](const char *field, const QString &value) {
            if (value.trimmed().isEmpty() && QString(field) != "keyword" && QString(field) != "suggest")
                o.remove(field);
            else if (value.trimmed() == original.value(field).toString())
                o.remove(field);
            else
                o[field] = value.trimmed();
        };
        store("name", name);
        store("keyword", keyword);
        store("url", url);
        store("suggest", suggestUrl);
        if (o.isEmpty())
            over.remove(key);
        else
            over[key] = o;
        saveOverrides(over);
        return;
    }
}

void SearchEngines::removeCustom(const QString &key) {
    auto list = customs();
    list.erase(std::remove_if(list.begin(), list.end(), [&key](const QVariantMap &m) { return m.value("key") == key; }),
               list.end());
    saveCustoms(list);
}

void SearchEngines::setHidden(const QString &key, bool hidden) {
    auto over = overrides();
    auto o = over.value(key).toObject();
    if (hidden)
        o["hidden"] = true;
    else
        o.remove("hidden");
    if (o.isEmpty())
        over.remove(key);
    else
        over[key] = o;
    saveOverrides(over);
}

void SearchEngines::resetBuiltin(const QString &key) {
    auto over = overrides();
    over.remove(key);
    saveOverrides(over);
}
