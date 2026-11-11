#include "dnr.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QSaveFile>
#include <QWebEngineUrlRequestInfo>
#include <algorithm>

namespace {

const char *const kTypeNames[] = {"main_frame", "sub_frame", "stylesheet", "script",    "image",
                                  "font",       "object",    "xmlhttprequest", "ping",  "csp_report",
                                  "media",      "websocket", "webtransport", "webbundle", "other"};
constexpr quint32 kAllTypes = (1u << Dnr::TypeCount) - 1;
constexpr int kStaticRuleBudget = 330000;

int typeFromName(const QString &name) {
    for (int i = 0; i < Dnr::TypeCount; ++i)
        if (name == QLatin1String(kTypeNames[i]))
            return i;
    return -1;
}

quint32 typeMask(const QJsonValue &value) {
    quint32 mask = 0;
    for (const auto &v : value.toArray()) {
        const int t = typeFromName(v.toString());
        if (t >= 0)
            mask |= 1u << t;
    }
    return mask;
}

QStringList lowerList(const QJsonValue &value) {
    QStringList out;
    for (const auto &v : value.toArray())
        out.append(v.toString().toLower());
    return out;
}

// The registrable part of a host, roughly (example.co.uk, example.com).
QString siteOf(const QString &host) {
    const auto parts = host.split('.', Qt::SkipEmptyParts);
    if (parts.size() <= 2)
        return host;
    static const QSet<QString> second = {"co", "com", "org", "net", "gov", "ac", "edu", "gouv", "ne", "or"};
    const int keep = parts.last().size() == 2 && second.contains(parts[parts.size() - 2]) ? 3 : 2;
    return parts.mid(parts.size() - keep).join('.');
}

bool isSeparator(QChar c) {
    return !(c.isLetterOrNumber() || c == '_' || c == '-' || c == '.' || c == '%');
}

bool matchFrom(const QString &f, int fi, int fe, const QString &u, int ui, bool endAnchor) {
    while (fi < fe) {
        const QChar c = f[fi];
        if (c == '*') {
            while (fi < fe && f[fi] == '*')
                ++fi;
            if (fi == fe)
                return true;
            for (int k = ui; k <= u.size(); ++k)
                if (matchFrom(f, fi, fe, u, k, endAnchor))
                    return true;
            return false;
        }
        if (c == '^') {
            if (ui == u.size()) {
                ++fi;
                continue;
            }
            if (!isSeparator(u[ui]))
                return false;
            ++ui;
            ++fi;
            continue;
        }
        if (ui >= u.size() || u[ui] != c)
            return false;
        ++ui;
        ++fi;
    }
    return !endAnchor || ui == u.size();
}

// The domain a filter is anchored to ("||ads.example.com^" -> ads.example.com),
// when the anchor covers a whole host.
QString anchoredDomain(const QString &filter) {
    if (!filter.startsWith("||"))
        return {};
    int i = 2;
    while (i < filter.size() && (filter[i].isLetterOrNumber() || filter[i] == '.' || filter[i] == '-'))
        ++i;
    if (i == 2 || filter[i - 1] == '.')
        return {};
    if (i == filter.size() || filter[i] == '^' || filter[i] == '/' || filter[i] == ':' ||
        (filter[i] == '|' && i == filter.size() - 1))
        return filter.mid(2, i - 2);
    return {};
}

void tokensOf(const QString &lower, QSet<QString> &out) {
    int start = -1;
    for (int i = 0; i <= lower.size(); ++i) {
        const bool word = i < lower.size() && ((lower[i] >= 'a' && lower[i] <= 'z') || (lower[i] >= '0' && lower[i] <= '9'));
        if (word && start < 0)
            start = i;
        else if (!word && start >= 0) {
            if (i - start >= 2)
                out.insert(lower.mid(start, i - start));
            start = -1;
        }
    }
}

} // namespace

Dnr::Dnr(const QString &directory) : m_directory(directory) { QDir().mkpath(directory); }

int Dnr::typeOf(int t) {
    switch (t) {
    case QWebEngineUrlRequestInfo::ResourceTypeMainFrame:
    case QWebEngineUrlRequestInfo::ResourceTypeNavigationPreloadMainFrame:
        return MainFrame;
    case QWebEngineUrlRequestInfo::ResourceTypeSubFrame:
    case QWebEngineUrlRequestInfo::ResourceTypeNavigationPreloadSubFrame:
        return SubFrame;
    case QWebEngineUrlRequestInfo::ResourceTypeStylesheet: return Stylesheet;
    case QWebEngineUrlRequestInfo::ResourceTypeScript: return Script;
    case QWebEngineUrlRequestInfo::ResourceTypeImage:
    case QWebEngineUrlRequestInfo::ResourceTypeFavicon:
        return Image;
    case QWebEngineUrlRequestInfo::ResourceTypeFontResource: return Font;
    case QWebEngineUrlRequestInfo::ResourceTypeObject:
    case QWebEngineUrlRequestInfo::ResourceTypePluginResource:
        return Object;
    case QWebEngineUrlRequestInfo::ResourceTypeXhr:
    case QWebEngineUrlRequestInfo::ResourceTypeJson:
        return XmlHttpRequest;
    case QWebEngineUrlRequestInfo::ResourceTypePing: return Ping;
    case QWebEngineUrlRequestInfo::ResourceTypeCspReport: return CspReport;
    case QWebEngineUrlRequestInfo::ResourceTypeMedia: return Media;
    case QWebEngineUrlRequestInfo::ResourceTypeWebSocket: return WebSocket;
    default: return Other;
    }
}

// ---------------------------------------------------------------- rules

Dnr::Rule Dnr::parseRule(const QJsonObject &o, QString *error) {
    Rule r;
    r.id = o.value("id").toInt();
    r.priority = std::max(1, o.value("priority").toInt(1));
    const auto action = o.value("action").toObject();
    const auto type = action.value("type").toString();
    if (type == "block") r.action = Block;
    else if (type == "allow") r.action = Allow;
    else if (type == "allowAllRequests") r.action = AllowAllRequests;
    else if (type == "upgradeScheme") r.action = UpgradeScheme;
    else if (type == "redirect") r.action = Redirect;
    else if (type == "modifyHeaders") r.action = ModifyHeaders;
    else if (error)
        *error = QString("Rule with id %1 has an invalid action type.").arg(r.id);
    r.redirect = action.value("redirect").toObject();
    r.requestHeaders = action.value("requestHeaders").toArray();

    const auto c = o.value("condition").toObject();
    r.caseSensitive = c.value("isUrlFilterCaseSensitive").toBool(false);
    r.urlFilter = c.value("urlFilter").toString();
    if (!r.caseSensitive)
        r.urlFilter = r.urlFilter.toLower();
    r.regexFilter = c.value("regexFilter").toString();
    r.requestDomains = lowerList(c.value("requestDomains"));
    r.excludedRequestDomains = lowerList(c.value("excludedRequestDomains"));
    r.initiatorDomains = lowerList(c.contains("initiatorDomains") ? c.value("initiatorDomains") : c.value("domains"));
    r.excludedInitiatorDomains =
        lowerList(c.contains("excludedInitiatorDomains") ? c.value("excludedInitiatorDomains") : c.value("excludedDomains"));
    const quint32 types = typeMask(c.value("resourceTypes"));
    r.excludedResourceTypes = typeMask(c.value("excludedResourceTypes"));
    r.resourceTypes = types ? types : (r.excludedResourceTypes ? kAllTypes : kAllTypes & ~(1u << MainFrame));
    r.resourceTypes &= ~r.excludedResourceTypes;
    if (r.action == AllowAllRequests && !(r.resourceTypes & ((1u << MainFrame) | (1u << SubFrame))) && error)
        *error = QString("Rule with id %1 is an allowAllRequests rule without main_frame or sub_frame.").arg(r.id);
    r.requestMethods = lowerList(c.value("requestMethods"));
    r.excludedRequestMethods = lowerList(c.value("excludedRequestMethods"));
    const auto domainType = c.value("domainType").toString();
    r.domainType = domainType == "firstParty" ? 1 : domainType == "thirdParty" ? 2 : 0;
    if (!r.regexFilter.isEmpty() && !r.urlFilter.isEmpty() && error)
        *error = QString("Rule with id %1 specifies both urlFilter and regexFilter.").arg(r.id);
    return r;
}

QJsonObject Dnr::ruleToJson(const Rule &r) {
    // Only used for tests and debugging: the original JSON is what extensions get back.
    QJsonObject o{{"id", r.id}, {"priority", r.priority}};
    o.insert("urlFilter", r.urlFilter);
    return o;
}

bool Dnr::matchUrlFilter(const QString &f, const QString &u, int hostStart, int hostEnd) {
    int fs = 0, fe = f.size();
    bool domainAnchor = false, startAnchor = false, endAnchor = false;
    if (f.startsWith("||")) {
        domainAnchor = true;
        fs = 2;
    } else if (f.startsWith('|')) {
        startAnchor = true;
        fs = 1;
    }
    if (fe > fs && f[fe - 1] == '|') {
        endAnchor = true;
        --fe;
    }
    if (fs == fe)
        return true;
    if (startAnchor)
        return matchFrom(f, fs, fe, u, 0, endAnchor);
    if (domainAnchor) {
        if (hostStart < 0 || hostEnd > u.size())
            return false;
        for (int i = hostStart; i < hostEnd; ++i)
            if ((i == hostStart || u[i - 1] == '.') && matchFrom(f, fs, fe, u, i, endAnchor))
                return true;
        return false;
    }
    const QChar first = f[fs];
    if (first != '*' && first != '^') {
        for (int i = u.indexOf(first); i >= 0; i = u.indexOf(first, i + 1))
            if (matchFrom(f, fs, fe, u, i, endAnchor))
                return true;
        return false;
    }
    for (int i = 0; i <= u.size(); ++i)
        if (matchFrom(f, fs, fe, u, i, endAnchor))
            return true;
    return false;
}

QString Dnr::tokenFor(const QString &f) {
    static const QSet<QString> common = {"http", "https", "www", "com", "net", "org", "js", "html", "php", "png", "jpg", "gif"};
    QString best;
    int i = 0;
    while (i < f.size()) {
        const auto word = [&](int k) { return k < f.size() && ((f[k] >= 'a' && f[k] <= 'z') || (f[k] >= '0' && f[k] <= '9')); };
        if (!word(i)) {
            ++i;
            continue;
        }
        int j = i;
        while (word(j))
            ++j;
        // A run is a whole token of the URL only when nothing wild touches it.
        // ("|", "||" and "^" bound a run as well as any other character).
        const bool leftOk = i > 0 && f[i - 1] != '*';
        const bool rightOk = j < f.size() && f[j] != '*';
        if (leftOk && rightOk && j - i >= 2) {
            const auto token = f.mid(i, j - i);
            if (!common.contains(token) && token.size() > best.size())
                best = token;
        }
        i = j;
    }
    return best;
}

bool Dnr::hostMatches(const QString &host, const QStringList &domains) {
    for (const auto &d : domains)
        if (host == d || (host.size() > d.size() && host.endsWith(d) && host[host.size() - d.size() - 1] == '.'))
            return true;
    return false;
}

bool Dnr::ruleMatches(Rule &r, const QString &url, const QString &lowerUrl, int hostStart, int hostEnd,
                      const QString &host, const QString &initiatorHost, bool thirdParty, int type,
                      const QString &method) const {
    if (!(r.resourceTypes & (1u << type)))
        return false;
    if (r.domainType == 1 && thirdParty)
        return false;
    if (r.domainType == 2 && !thirdParty)
        return false;
    if (!r.requestDomains.isEmpty() && !hostMatches(host, r.requestDomains))
        return false;
    if (!r.excludedRequestDomains.isEmpty() && hostMatches(host, r.excludedRequestDomains))
        return false;
    if (!r.initiatorDomains.isEmpty() && (initiatorHost.isEmpty() || !hostMatches(initiatorHost, r.initiatorDomains)))
        return false;
    if (!r.excludedInitiatorDomains.isEmpty() && !initiatorHost.isEmpty() &&
        hostMatches(initiatorHost, r.excludedInitiatorDomains))
        return false;
    if (!r.requestMethods.isEmpty() && !r.requestMethods.contains(method))
        return false;
    if (!r.excludedRequestMethods.isEmpty() && r.excludedRequestMethods.contains(method))
        return false;
    if (!r.regexFilter.isEmpty()) {
        if (!r.regex) {
            r.regex = std::make_shared<QRegularExpression>(
                r.regexFilter, r.caseSensitive ? QRegularExpression::NoPatternOption : QRegularExpression::CaseInsensitiveOption);
            r.regex->optimize();
        }
        return r.regex->isValid() && r.regex->match(url).hasMatch();
    }
    if (!r.urlFilter.isEmpty())
        return matchUrlFilter(r.urlFilter, r.caseSensitive ? url : lowerUrl, hostStart, hostEnd);
    return true;
}

// ---------------------------------------------------------------- matching

Dnr::Outcome Dnr::evaluate(const QUrl &url, const QUrl &initiator, const QUrl &firstParty, int qtType,
                           const QByteArray &rawMethod) {
    Outcome out;
    if (m_extensions.isEmpty())
        return out;
    const int type = typeOf(qtType);
    const auto scheme = url.scheme();
    if (scheme != "http" && scheme != "https" && scheme != "ws" && scheme != "wss")
        return out;
    const auto text = url.toString(QUrl::FullyEncoded);
    const auto lower = text.toLower();
    const auto host = url.host(QUrl::FullyEncoded).toLower();
    int hostStart = lower.indexOf("://") + 3;
    const int at = lower.indexOf('@', hostStart);
    const int slash = lower.indexOf('/', hostStart);
    if (at >= 0 && (slash < 0 || at < slash))
        hostStart = at + 1;
    // Hosts are compared in their ASCII form (xn--…), as rules write them.
    hostStart = lower.indexOf(host, hostStart);
    if (hostStart < 0 || host.isEmpty())
        return out;
    const int hostEnd = hostStart + host.size();
    QString initiatorHost = initiator.host(QUrl::FullyEncoded).toLower();
    if (initiatorHost.isEmpty() && type != MainFrame)
        initiatorHost = firstParty.host(QUrl::FullyEncoded).toLower();
    const bool thirdParty = !initiatorHost.isEmpty() && siteOf(host) != siteOf(initiatorHost);
    const auto method = QString::fromLatin1(rawMethod).toLower();

    QUrl page = firstParty;
    page.setFragment({});
    const auto pageKey = page.toString();
    QUrl self = url;
    self.setFragment({});
    if (type == MainFrame) {
        m_allowAllPages.remove(self.toString());
        const auto site = siteOf(host);
        for (auto it = m_blocked.begin(); it != m_blocked.end(); ++it)
            it->remove(site);
    }

    // Candidates.
    std::vector<Rule *> candidates;
    for (int i = 0; i >= 0 && i < host.size(); i = host.indexOf('.', i) < 0 ? -1 : host.indexOf('.', i) + 1) {
        const auto it = m_byDomain.constFind(host.mid(i));
        if (it != m_byDomain.constEnd())
            candidates.insert(candidates.end(), it->begin(), it->end());
    }
    QSet<QString> tokens;
    tokensOf(lower, tokens);
    for (const auto &t : tokens) {
        const auto it = m_byToken.constFind(t);
        if (it != m_byToken.constEnd())
            candidates.insert(candidates.end(), it->begin(), it->end());
    }
    candidates.insert(candidates.end(), m_generic.begin(), m_generic.end());

    static const int rank[] = {2, 0, 1, 3, 4, 5}; // Block, Allow, AllowAll, Upgrade, Redirect, ModifyHeaders
    Rule *best = nullptr;
    std::vector<Rule *> headerRules;
    for (Rule *r : candidates) {
        if (!ruleMatches(*r, text, lower, hostStart, hostEnd, host, initiatorHost, thirdParty, type, method))
            continue;
        if (r->action == ModifyHeaders) {
            headerRules.push_back(r);
            continue;
        }
        if (!best || r->priority > best->priority || (r->priority == best->priority && rank[r->action] < rank[best->action]))
            best = r;
    }
    const auto allowAll = m_allowAllPages.constFind(pageKey);
    if (type != MainFrame && allowAll != m_allowAllPages.constEnd() && (!best || *allowAll >= best->priority)) {
        out.matched = true;
        return out;
    }
    if (best && best->action == AllowAllRequests && (type == MainFrame || type == SubFrame))
        m_allowAllPages.insert(self.toString(), best->priority);
    if (!best && headerRules.empty())
        return out;

    if (best) {
        out.matched = true;
        const auto &set = *m_sets[best->set];
        out.extension = set.extension;
        out.ruleId = best->id;
        out.rulesetId = set.id;
        if (best->action == Block) {
            out.block = true;
            m_blocked[set.extension][siteOf(firstParty.host(QUrl::FullyEncoded).toLower().isEmpty() ? host : firstParty.host(QUrl::FullyEncoded).toLower())]++;
        } else if (best->action == UpgradeScheme && (scheme == "http" || scheme == "ws")) {
            QUrl up = url;
            up.setScheme(scheme == "http" ? "https" : "wss");
            if (up.port() == 80)
                up.setPort(-1);
            out.redirect = up;
        } else if (best->action == Redirect) {
            out.redirect = redirectFor(*best, url);
        }
        if (best->action == Allow || best->action == AllowAllRequests)
            return out;
    }
    if (!out.block)
        for (const Rule *r : headerRules)
            for (const auto &h : r->requestHeaders) {
                const auto o = h.toObject();
                const auto op = o.value("operation").toString();
                if (op == "set" || op == "append")
                    out.headers.append({o.value("header").toString().toLatin1(), o.value("value").toString().toUtf8()});
                out.matched = true;
            }
    return out;
}

QUrl Dnr::redirectFor(const Rule &r, const QUrl &url) const {
    const auto &d = r.redirect;
    const auto &set = *m_sets[r.set];
    if (d.contains("url"))
        return QUrl(d.value("url").toString());
    if (d.contains("extensionPath")) {
        const auto path = d.value("extensionPath").toString();
        if (m_fileUrl)
            return m_fileUrl(set.extension, path);
        return QUrl("chrome-extension://" + set.extension + path);
    }
    if (d.contains("regexSubstitution") && r.regex && r.regex->isValid()) {
        const auto m = r.regex->match(url.toString(QUrl::FullyEncoded));
        if (!m.hasMatch())
            return {};
        auto sub = d.value("regexSubstitution").toString();
        QString out;
        for (int i = 0; i < sub.size(); ++i) {
            if (sub[i] == '\\' && i + 1 < sub.size() && sub[i + 1].isDigit()) {
                out += m.captured(sub[i + 1].digitValue());
                ++i;
            } else {
                out += sub[i];
            }
        }
        return QUrl(out);
    }
    if (d.contains("transform")) {
        const auto t = d.value("transform").toObject();
        QUrl u = url;
        if (t.contains("scheme")) u.setScheme(t.value("scheme").toString());
        if (t.contains("host")) u.setHost(t.value("host").toString());
        if (t.contains("port")) u.setPort(t.value("port").toString().isEmpty() ? -1 : t.value("port").toString().toInt());
        if (t.contains("path")) u.setPath(t.value("path").toString());
        if (t.contains("query")) u.setQuery(t.value("query").toString().mid(t.value("query").toString().startsWith('?') ? 1 : 0));
        if (t.contains("fragment")) u.setFragment(t.value("fragment").toString().mid(1));
        if (t.contains("username")) u.setUserName(t.value("username").toString());
        if (t.contains("password")) u.setPassword(t.value("password").toString());
        if (t.contains("queryTransform")) {
            const auto qt = t.value("queryTransform").toObject();
            QStringList remove;
            for (const auto &v : qt.value("removeParams").toArray())
                remove.append(v.toString());
            QList<QPair<QString, QString>> items;
            for (const auto &pair : u.query(QUrl::FullyEncoded).split('&', Qt::SkipEmptyParts)) {
                const int eq = pair.indexOf('=');
                const auto key = eq < 0 ? pair : pair.left(eq);
                if (!remove.contains(QUrl::fromPercentEncoding(key.toUtf8())))
                    items.append({key, eq < 0 ? QString() : pair.mid(eq + 1)});
            }
            for (const auto &v : qt.value("addOrReplaceParams").toArray()) {
                const auto o = v.toObject();
                const auto key = QString::fromUtf8(QUrl::toPercentEncoding(o.value("key").toString()));
                const auto value = QString::fromUtf8(QUrl::toPercentEncoding(o.value("value").toString()));
                bool done = false;
                for (auto &item : items)
                    if (item.first == key) {
                        item.second = value;
                        done = true;
                        break;
                    }
                if (!done && !o.value("replaceOnly").toBool())
                    items.append({key, value});
            }
            QStringList parts;
            for (const auto &item : items)
                parts.append(item.second.isNull() ? item.first : item.first + "=" + item.second);
            u.setQuery(parts.join('&'), QUrl::StrictMode);
        }
        return u;
    }
    return {};
}

bool Dnr::apply(const Outcome &o, QWebEngineUrlRequestInfo &info) {
    if (!o.matched)
        return false;
    for (const auto &h : o.headers)
        info.setHttpHeader(h.first, h.second);
    if (o.block) {
        info.block(true);
        return true;
    }
    if (o.redirect.isValid() && o.redirect != info.requestUrl()) {
        info.redirect(o.redirect);
        return true;
    }
    return false;
}

int Dnr::blockedOn(const QString &extension, const QString &pageUrl) const {
    return m_blocked.value(extension).value(siteOf(QUrl(pageUrl).host(QUrl::FullyEncoded).toLower()));
}

// ---------------------------------------------------------------- extensions & state

void Dnr::setExtension(const QString &id, const QString &path) {
    QFile file(path + "/manifest.json");
    if (!file.open(QIODevice::ReadOnly))
        return;
    const auto manifest = QJsonDocument::fromJson(file.readAll()).object();
    const auto resources = manifest.value("declarative_net_request").toObject().value("rule_resources").toArray();
    if (resources.isEmpty() && !manifest.value("permissions").toArray().contains(QJsonValue("declarativeNetRequest")) &&
        !manifest.value("permissions").toArray().contains(QJsonValue("declarativeNetRequestWithHostAccess")))
        return;
    if (m_extensions.contains(id) && m_extensions[id].path == path)
        return;
    Extension ext;
    ext.path = path;
    ext.resources = resources;
    for (const auto &r : resources)
        if (r.toObject().value("enabled").toBool())
            ext.enabled.append(r.toObject().value("id").toString());
    loadState(id, ext);
    m_extensions.insert(id, ext);
    rebuild();
}

void Dnr::removeExtension(const QString &id) {
    if (m_extensions.remove(id)) {
        m_blocked.remove(id);
        rebuild();
    }
}

void Dnr::loadState(const QString &id, Extension &ext) {
    QFile file(m_directory + "/" + id + ".json");
    if (!file.open(QIODevice::ReadOnly))
        return;
    QJsonParseError error;
    const auto o = QJsonDocument::fromJson(file.readAll(), &error).object();
    if (error.error != QJsonParseError::NoError) {
        // An extension's own rules: kept aside rather than lost on the next save.
        file.close();
        QFile::rename(file.fileName(), file.fileName() + ".corrupt");
        return;
    }
    if (o.contains("enabled")) {
        ext.enabled.clear();
        for (const auto &v : o.value("enabled").toArray())
            ext.enabled.append(v.toString());
    }
    ext.dynamicRules = o.value("dynamic").toArray();
    const auto disabled = o.value("disabledStatic").toObject();
    for (auto it = disabled.begin(); it != disabled.end(); ++it)
        for (const auto &v : it->toArray())
            ext.disabledStatic[it.key()].insert(v.toInt());
    ext.actionCountBadge = o.value("actionCountBadge").toBool();
}

void Dnr::saveState(const QString &id) const {
    const auto &ext = m_extensions[id];
    QJsonObject disabled;
    for (auto it = ext.disabledStatic.begin(); it != ext.disabledStatic.end(); ++it) {
        QJsonArray ids;
        for (int v : *it)
            ids.append(v);
        disabled.insert(it.key(), ids);
    }
    const QJsonObject o{{"enabled", QJsonArray::fromStringList(ext.enabled)},
                        {"dynamic", ext.dynamicRules},
                        {"disabledStatic", disabled},
                        {"actionCountBadge", ext.actionCountBadge}};
    QSaveFile file(m_directory + "/" + id + ".json");
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
        file.commit();
    }
}

void Dnr::rebuild() {
    // Static rulesets are parsed once and kept; the rest is rebuilt.
    std::vector<std::unique_ptr<RuleSet>> keep;
    for (auto &set : m_sets)
        if (set && set->id != "_dynamic" && set->id != "_session" && m_extensions.contains(set->extension) &&
            m_extensions[set->extension].enabled.contains(set->id))
            keep.push_back(std::move(set));
    m_sets = std::move(keep);
    m_byDomain.clear();
    m_byToken.clear();
    m_generic.clear();
    m_allowAllPages.clear();

    auto addSet = [this](const QString &extension, const QString &id, const QJsonArray &rules) {
        auto set = std::make_unique<RuleSet>();
        set->extension = extension;
        set->id = id;
        set->rules.reserve(rules.size());
        for (const auto &v : rules) {
            QString error;
            auto rule = parseRule(v.toObject(), &error);
            if (error.isEmpty())
                set->rules.push_back(std::move(rule));
        }
        m_sets.push_back(std::move(set));
    };
    for (auto it = m_extensions.begin(); it != m_extensions.end(); ++it) {
        for (const auto &r : it->resources) {
            const auto o = r.toObject();
            const auto id = o.value("id").toString();
            if (!it->enabled.contains(id))
                continue;
            const bool loaded = std::any_of(m_sets.begin(), m_sets.end(),
                                            [&](const auto &s) { return s->extension == it.key() && s->id == id; });
            if (loaded)
                continue;
            QFile file(it->path + "/" + o.value("path").toString().remove(QRegularExpression("^/+")));
            if (file.open(QIODevice::ReadOnly))
                addSet(it.key(), id, QJsonDocument::fromJson(file.readAll()).array());
        }
        addSet(it.key(), "_dynamic", it->dynamicRules);
        addSet(it.key(), "_session", it->sessionRules);
    }
    for (int s = 0; s < int(m_sets.size()); ++s) {
        auto &set = *m_sets[s];
        const auto disabled = m_extensions.value(set.extension).disabledStatic.value(set.id);
        for (auto &rule : set.rules) {
            rule.set = s;
            if (disabled.contains(rule.id))
                continue;
            const auto domain = anchoredDomain(rule.urlFilter);
            if (!domain.isEmpty()) {
                m_byDomain[domain].push_back(&rule);
                continue;
            }
            if (rule.regexFilter.isEmpty()) {
                const auto token = tokenFor(rule.caseSensitive ? rule.urlFilter.toLower() : rule.urlFilter);
                if (!token.isEmpty()) {
                    m_byToken[token].push_back(&rule);
                    continue;
                }
            }
            if (!rule.requestDomains.isEmpty()) {
                for (const auto &d : rule.requestDomains)
                    m_byDomain[d].push_back(&rule);
                continue;
            }
            m_generic.push_back(&rule);
        }
    }
}

int Dnr::ruleCount() const {
    int n = 0;
    for (const auto &s : m_sets)
        n += int(s->rules.size());
    return n;
}

// ---------------------------------------------------------------- the extension API

QVariant Dnr::call(const QString &id, const QString &method, const QVariantList &args, QString *error) {
    auto it = m_extensions.find(id);
    if (it == m_extensions.end()) {
        // An extension with the permission but no static rules.
        Extension ext;
        loadState(id, ext);
        it = m_extensions.insert(id, ext);
    }
    Extension &ext = *it;
    const auto arg = args.value(0).toMap();

    auto updateRules = [&](QJsonArray &list, bool persist) -> QVariant {
        QSet<int> remove;
        for (const auto &v : arg.value("removeRuleIds").toList())
            remove.insert(v.toInt());
        QJsonArray next;
        QSet<int> ids;
        for (const auto &v : list)
            if (!remove.contains(v.toObject().value("id").toInt())) {
                next.append(v);
                ids.insert(v.toObject().value("id").toInt());
            }
        for (const auto &v : arg.value("addRules").toList()) {
            const auto o = QJsonObject::fromVariantMap(v.toMap());
            QString problem;
            const auto rule = parseRule(o, &problem);
            if (problem.isEmpty() && ids.contains(rule.id))
                problem = QString("Rule with id %1 does not have a unique ID.").arg(rule.id);
            if (problem.isEmpty() && rule.id < 1)
                problem = "Rule with id must be at least 1.";
            if (!problem.isEmpty()) {
                *error = problem;
                return {};
            }
            ids.insert(rule.id);
            next.append(o);
        }
        list = next;
        if (persist)
            saveState(id);
        rebuild();
        return {};
    };
    auto filtered = [&](const QJsonArray &list) {
        QVariantList out;
        QSet<int> wanted;
        for (const auto &v : arg.value("ruleIds").toList())
            wanted.insert(v.toInt());
        for (const auto &v : list)
            if (wanted.isEmpty() || wanted.contains(v.toObject().value("id").toInt()))
                out.append(v.toObject().toVariantMap());
        return out;
    };

    if (method == "getEnabledRulesets")
        return ext.enabled;
    if (method == "updateEnabledRulesets") {
        QStringList known;
        for (const auto &r : ext.resources)
            known.append(r.toObject().value("id").toString());
        for (const auto &v : arg.value("disableRulesetIds").toList())
            ext.enabled.removeAll(v.toString());
        for (const auto &v : arg.value("enableRulesetIds").toList()) {
            if (!known.contains(v.toString())) {
                *error = "Invalid ruleset id: " + v.toString() + ".";
                return {};
            }
            if (!ext.enabled.contains(v.toString()))
                ext.enabled.append(v.toString());
        }
        saveState(id);
        rebuild();
        return {};
    }
    if (method == "getAvailableStaticRuleCount") {
        int used = 0;
        for (const auto &s : m_sets)
            if (s->extension == id && s->id != "_dynamic" && s->id != "_session")
                used += int(s->rules.size());
        return std::max(0, kStaticRuleBudget - used);
    }
    if (method == "getDynamicRules")
        return filtered(ext.dynamicRules);
    if (method == "updateDynamicRules")
        return updateRules(ext.dynamicRules, true);
    if (method == "getSessionRules")
        return filtered(ext.sessionRules);
    if (method == "updateSessionRules")
        return updateRules(ext.sessionRules, false);
    if (method == "updateStaticRules") {
        auto &set = ext.disabledStatic[arg.value("rulesetId").toString()];
        for (const auto &v : arg.value("disableRuleIds").toList())
            set.insert(v.toInt());
        for (const auto &v : arg.value("enableRuleIds").toList())
            set.remove(v.toInt());
        saveState(id);
        rebuild();
        return {};
    }
    if (method == "getDisabledRuleIds") {
        QVariantList out;
        for (int v : ext.disabledStatic.value(arg.value("rulesetId").toString()))
            out.append(v);
        return out;
    }
    if (method == "isRegexSupported") {
        const QRegularExpression re(arg.value("regex").toString());
        if (re.isValid())
            return QVariantMap{{"isSupported", true}};
        return QVariantMap{{"isSupported", false}, {"reason", "syntaxError"}};
    }
    if (method == "setExtensionActionOptions") {
        if (arg.contains("displayActionCountAsBadgeText")) {
            ext.actionCountBadge = arg.value("displayActionCountAsBadgeText").toBool();
            saveState(id);
        }
        return {};
    }
    if (method == "getMatchedRules")
        return QVariantMap{{"rulesMatchedInfo", QVariantList()}};
    if (method == "testMatchOutcome")
        return QVariantMap{{"matchedRules", QVariantList()}};
    if (method == "actionCountBadge")
        return ext.actionCountBadge;
    *error = "declarativeNetRequest." + method + " n'est pas pris en charge.";
    return {};
}
