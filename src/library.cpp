#include "library.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonParseError>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUrl>
#include <algorithm>
#include <cmath>

static const int kHistoryCap = 20000;
static const int kDownloadsCap = 300;

Library::Library(const QString &directory, QObject *parent)
    : QObject(parent),
      m_directory(directory.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/flairweb" : directory) {
    QDir().mkpath(m_directory);
    m_history = load("history");
    m_bookmarks = load("bookmarks");
    m_downloads = load("downloads");
    for (const auto &v : load("zoom")) {
        const auto o = v.toObject();
        m_zoom.insert(o.value("host").toString(), o.value("zoom").toDouble());
    }
    for (int i = 0; i < m_history.size(); ++i)
        m_historyIndex.insert(m_history.at(i).toObject().value("url").toString(), i);
    // First run: a few places to start from, editable on the new tab page.
    if (!QFileInfo::exists(m_directory + "/dial.json")) {
        const QList<QPair<QString, QString>> seeds{{"https://fr.wikipedia.org/", "Wikipédia"},
                                                   {"https://www.youtube.com/", "YouTube"},
                                                   {"https://github.com/", "GitHub"},
                                                   {"https://claude.ai/", "Claude"},
                                                   {"https://www.reddit.com/", "Reddit"},
                                                   {"https://wiki.archlinux.org/", "ArchWiki"}};
        for (const auto &s : seeds)
            m_dial.append(QJsonObject{{"url", s.first}, {"title", s.second}});
        save("dial", m_dial);
    } else {
        m_dial = load("dial");
    }
    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(1500);
    connect(&m_saveTimer, &QTimer::timeout, this, &Library::flush);
}

Library::~Library() { flush(); }

QJsonArray Library::load(const QString &name) const {
    QFile file(m_directory + "/" + name + ".json");
    if (!file.open(QIODevice::ReadOnly))
        return {};
    const auto data = file.readAll();
    QJsonParseError error;
    const auto doc = QJsonDocument::fromJson(data, &error);
    if (error.error != QJsonParseError::NoError && !data.trimmed().isEmpty()) {
        // Unreadable: kept aside rather than overwritten by the next save.
        file.close();
        const auto aside = file.fileName() + ".corrupt-" + QDateTime::currentDateTime().toString("yyyyMMdd-HHmmss");
        QFile::rename(file.fileName(), aside);
        qWarning().noquote() << "Flair Web :" << file.fileName() << "illisible (" + error.errorString() + "), gardé dans" << aside;
        return {};
    }
    return doc.array();
}

void Library::save(const QString &name, const QJsonArray &array) const {
    QSaveFile file(m_directory + "/" + name + ".json");
    if (!file.open(QIODevice::WriteOnly))
        return;
    file.write(QJsonDocument(array).toJson(QJsonDocument::Compact));
    if (file.commit())
        QFile::setPermissions(file.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

void Library::schedule(const QString &name) {
    if (!m_dirty.contains(name))
        m_dirty.append(name);
    m_saveTimer.start();
}

void Library::flush() {
    m_saveTimer.stop();
    for (const auto &name : std::as_const(m_dirty)) {
        if (name == "history")
            save(name, m_history);
        else if (name == "bookmarks")
            save(name, m_bookmarks);
        else if (name == "dial")
            save(name, m_dial);
        else if (name == "downloads")
            save(name, m_downloads);
        else if (name == "zoom") {
            QJsonArray array;
            for (auto it = m_zoom.cbegin(); it != m_zoom.cend(); ++it)
                array.append(QJsonObject{{"host", it.key()}, {"zoom", it.value()}});
            save(name, array);
        }
    }
    m_dirty.clear();
}

QString Library::hostOf(const QString &url) {
    auto host = QUrl(url).host().toLower();
    if (host.startsWith("www."))
        host = host.mid(4);
    return host;
}

QString Library::fold(const QString &text) {
    const auto decomposed = text.toLower().normalized(QString::NormalizationForm_D);
    QString out;
    out.reserve(decomposed.size());
    for (const auto ch : decomposed)
        if (ch.category() != QChar::Mark_NonSpacing)
            out.append(ch);
    return out;
}

// ---------------------------------------------------------------- history

bool Library::recordable(const QString &url) {
    static const QRegularExpression skip(R"(^(about|chrome|data|view-source|devtools|blob|qrc|chrome-extension):)");
    return !url.isEmpty() && !skip.match(url).hasMatch();
}

int Library::findHistory(const QString &url) const { return m_historyIndex.value(url, -1); }

void Library::visit(const QString &url, const QString &title) {
    if (!recordable(url))
        return;
    const double now = double(QDateTime::currentMSecsSinceEpoch());
    const int i = findHistory(url);
    if (i >= 0) {
        auto o = m_history.at(i).toObject();
        // Reloads and redirects within a few seconds do not count twice.
        if (now - o.value("last").toDouble() > 5000)
            o["count"] = o.value("count").toInt() + 1;
        o["last"] = now;
        if (!title.trimmed().isEmpty())
            o["title"] = title.trimmed();
        m_history[i] = o;
    } else {
        m_history.append(QJsonObject{{"url", url}, {"title", title.trimmed()}, {"last", now}, {"count", 1}});
        m_historyIndex.insert(url, m_history.size() - 1);
        if (m_history.size() > kHistoryCap) {
            // Drop the oldest tenth in one go.
            QList<QJsonObject> all;
            for (const auto &v : std::as_const(m_history))
                all.append(v.toObject());
            std::sort(all.begin(), all.end(), [](const QJsonObject &a, const QJsonObject &b) {
                return a.value("last").toDouble() > b.value("last").toDouble();
            });
            all.resize(kHistoryCap * 9 / 10);
            m_history = QJsonArray();
            m_historyIndex.clear();
            for (const auto &o : std::as_const(all)) {
                m_history.append(o);
                m_historyIndex.insert(o.value("url").toString(), m_history.size() - 1);
            }
        }
    }
    ++m_historyRevision;
    schedule("history");
    emit historyChanged();
}

void Library::updateTitle(const QString &url, const QString &title) {
    const int i = findHistory(url);
    if (i < 0 || title.trimmed().isEmpty())
        return;
    auto o = m_history.at(i).toObject();
    if (o.value("title").toString() == title.trimmed())
        return;
    o["title"] = title.trimmed();
    m_history[i] = o;
    ++m_historyRevision;
    schedule("history");
    emit historyChanged();
}

static bool matchesAll(const QString &haystack, const QStringList &words) {
    for (const auto &w : words)
        if (!haystack.contains(w))
            return false;
    return true;
}

QVariantList Library::history(const QString &query, int limit) const {
    const auto words = fold(query).split(' ', Qt::SkipEmptyParts);
    QList<QJsonObject> matches;
    // Newest entries are at the end: walk backwards so equal times keep that order.
    for (qsizetype i = m_history.size() - 1; i >= 0; --i) {
        const auto o = m_history.at(i).toObject();
        if (words.isEmpty() || matchesAll(fold(o.value("title").toString() + " " + o.value("url").toString()), words))
            matches.append(o);
    }
    std::stable_sort(matches.begin(), matches.end(), [](const QJsonObject &a, const QJsonObject &b) {
        return a.value("last").toDouble() > b.value("last").toDouble();
    });
    QVariantList out;
    for (int i = 0; i < matches.size() && i < limit; ++i) {
        auto map = matches.at(i).toVariantMap();
        map["host"] = hostOf(map.value("url").toString());
        out.append(map);
    }
    return out;
}

QVariantList Library::suggest(const QString &query, int limit) const {
    const auto q = fold(query.trimmed());
    if (q.isEmpty())
        return {};
    const auto words = q.split(' ', Qt::SkipEmptyParts);
    const double now = double(QDateTime::currentMSecsSinceEpoch());
    QList<QPair<double, QJsonObject>> scored;
    for (const auto &v : m_history) {
        const auto o = v.toObject();
        const auto url = o.value("url").toString();
        const auto title = o.value("title").toString();
        const auto foldedUrl = fold(url);
        if (!matchesAll(fold(title) + " " + foldedUrl, words))
            continue;
        const auto host = hostOf(url);
        const double age = (now - o.value("last").toDouble()) / 86400000.0;
        double score = std::log(1.0 + o.value("count").toInt()) * 12.0;
        score += age < 1 ? 40 : age < 7 ? 25 : age < 30 ? 10 : 0;
        if (host.startsWith(q))
            score += 120;
        else if (foldedUrl.contains("://" + q) || foldedUrl.contains("://www." + q))
            score += 100;
        if (fold(title).startsWith(q))
            score += 20;
        // Shorter addresses (home pages) rank above deep links of the same site.
        score -= std::min<double>(url.size(), 200) * 0.05;
        scored.append({score, o});
    }
    std::sort(scored.begin(), scored.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
    QVariantList out;
    for (int i = 0; i < scored.size() && out.size() < limit; ++i) {
        auto map = scored.at(i).second.toVariantMap();
        map["kind"] = "history";
        map["host"] = hostOf(map.value("url").toString());
        out.append(map);
    }
    return out;
}

QVariantList Library::topSites(int limit) const {
    struct Site {
        double weight = 0;
        double last = 0;
        QString url, title, rootTitle;
        int rootCount = -1;
    };
    QHash<QString, Site> sites;
    for (const auto &v : m_history) {
        const auto o = v.toObject();
        const QUrl url(o.value("url").toString());
        if (url.scheme() != "http" && url.scheme() != "https")
            continue;
        const auto host = hostOf(url.toString());
        auto &site = sites[host];
        site.weight += o.value("count").toInt();
        site.last = std::max(site.last, o.value("last").toDouble());
        const bool root = url.path().size() <= 1 && url.query().isEmpty();
        if (root && o.value("count").toInt() > site.rootCount) {
            site.rootCount = o.value("count").toInt();
            site.rootTitle = o.value("title").toString();
            site.url = url.toString();
        }
        if (site.url.isEmpty())
            site.url = url.scheme() + "://" + url.host() + "/";
    }
    QList<QPair<QString, Site>> list;
    for (auto it = sites.cbegin(); it != sites.cend(); ++it)
        list.append({it.key(), it.value()});
    std::sort(list.begin(), list.end(), [](const auto &a, const auto &b) {
        return a.second.weight != b.second.weight ? a.second.weight > b.second.weight : a.second.last > b.second.last;
    });
    QVariantList out;
    for (int i = 0; i < list.size() && i < limit; ++i) {
        const auto &s = list.at(i).second;
        out.append(QVariantMap{{"url", s.url},
                               {"title", s.rootTitle.isEmpty() ? list.at(i).first : s.rootTitle},
                               {"host", list.at(i).first}});
    }
    return out;
}

void Library::removeHistory(const QString &url) {
    const int i = findHistory(url);
    if (i < 0)
        return;
    m_history.removeAt(i);
    m_historyIndex.clear();
    for (int j = 0; j < m_history.size(); ++j)
        m_historyIndex.insert(m_history.at(j).toObject().value("url").toString(), j);
    ++m_historyRevision;
    schedule("history");
    emit historyChanged();
}

void Library::clearHistory(double sinceMs) {
    if (sinceMs <= 0) {
        m_history = QJsonArray();
    } else {
        QJsonArray kept;
        for (const auto &v : std::as_const(m_history))
            if (v.toObject().value("last").toDouble() < sinceMs)
                kept.append(v);
        m_history = kept;
    }
    m_historyIndex.clear();
    for (int j = 0; j < m_history.size(); ++j)
        m_historyIndex.insert(m_history.at(j).toObject().value("url").toString(), j);
    ++m_historyRevision;
    schedule("history");
    emit historyChanged();
}

// ---------------------------------------------------------------- bookmarks

int Library::findBookmark(const QString &url) const {
    for (int i = 0; i < m_bookmarks.size(); ++i)
        if (m_bookmarks.at(i).toObject().value("url").toString() == url)
            return i;
    return -1;
}

bool Library::isBookmarked(const QString &url) const { return !url.isEmpty() && findBookmark(url) >= 0; }

void Library::addBookmark(const QString &url, const QString &title, const QString &folder) {
    if (url.isEmpty() || isBookmarked(url))
        return;
    m_bookmarks.append(QJsonObject{{"url", url},
                                   {"title", title.trimmed().isEmpty() ? hostOf(url) : title.trimmed()},
                                   {"folder", folder.trimmed()},
                                   {"added", double(QDateTime::currentMSecsSinceEpoch())}});
    ++m_bookmarksRevision;
    schedule("bookmarks");
    emit bookmarksChanged();
}

void Library::removeBookmark(const QString &url) {
    const int i = findBookmark(url);
    if (i < 0)
        return;
    m_bookmarks.removeAt(i);
    ++m_bookmarksRevision;
    schedule("bookmarks");
    emit bookmarksChanged();
}

bool Library::toggleBookmark(const QString &url, const QString &title) {
    if (isBookmarked(url)) {
        removeBookmark(url);
        return false;
    }
    addBookmark(url, title);
    return true;
}

void Library::editBookmark(const QString &url, const QString &title, const QString &newUrl, const QString &folder) {
    const int i = findBookmark(url);
    if (i < 0)
        return;
    auto o = m_bookmarks.at(i).toObject();
    if (!title.trimmed().isEmpty())
        o["title"] = title.trimmed();
    if (!newUrl.trimmed().isEmpty())
        o["url"] = newUrl.trimmed();
    o["folder"] = folder.trimmed();
    m_bookmarks[i] = o;
    ++m_bookmarksRevision;
    schedule("bookmarks");
    emit bookmarksChanged();
}

void Library::moveBookmark(int from, int to) {
    if (from < 0 || from >= m_bookmarks.size() || to < 0 || to >= m_bookmarks.size() || from == to)
        return;
    const auto item = m_bookmarks.at(from);
    m_bookmarks.removeAt(from);
    m_bookmarks.insert(to, item);
    ++m_bookmarksRevision;
    schedule("bookmarks");
    emit bookmarksChanged();
}

QVariantList Library::bookmarks(const QString &query) const {
    const auto words = fold(query).split(' ', Qt::SkipEmptyParts);
    QVariantList out;
    for (int i = 0; i < m_bookmarks.size(); ++i) {
        const auto o = m_bookmarks.at(i).toObject();
        if (!words.isEmpty() &&
            !matchesAll(fold(o.value("title").toString() + " " + o.value("url").toString() + " " +
                             o.value("folder").toString()),
                        words))
            continue;
        auto map = o.toVariantMap();
        map["index"] = i;
        map["kind"] = "bookmark";
        map["host"] = hostOf(o.value("url").toString());
        out.append(map);
    }
    return out;
}

QVariantMap Library::bookmark(const QString &url) const {
    const int i = findBookmark(url);
    return i < 0 ? QVariantMap{} : m_bookmarks.at(i).toObject().toVariantMap();
}

QStringList Library::folders() const {
    QStringList out;
    for (const auto &v : m_bookmarks) {
        const auto f = v.toObject().value("folder").toString();
        if (!f.isEmpty() && !out.contains(f))
            out.append(f);
    }
    return out;
}

static void walkChromium(const QJsonObject &node, const QString &folder, QList<QPair<QString, QPair<QString, QString>>> &out) {
    const auto type = node.value("type").toString();
    if (type == "url") {
        out.append({folder, {node.value("url").toString(), node.value("name").toString()}});
        return;
    }
    for (const auto &child : node.value("children").toArray()) {
        const auto c = child.toObject();
        walkChromium(c, c.value("type").toString() == "folder" ? c.value("name").toString() : folder, out);
    }
}

int Library::importBookmarks(const QString &rawPath) {
    const auto path = rawPath.startsWith("file:") ? QUrl(rawPath).toLocalFile() : rawPath;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return -1;
    const auto bytes = file.readAll();
    QList<QPair<QString, QPair<QString, QString>>> found; // folder, (url, title)
    const auto json = QJsonDocument::fromJson(bytes);
    if (json.isObject()) {
        const auto roots = json.object().value("roots").toObject();
        walkChromium(roots.value("bookmark_bar").toObject(), "", found);
        walkChromium(roots.value("other").toObject(), "Autres favoris", found);
        walkChromium(roots.value("synced").toObject(), "Mobile", found);
    } else {
        // Netscape bookmark file (Firefox, Safari, every Chromium export).
        const auto text = QString::fromUtf8(bytes);
        static const QRegularExpression token(
            R"re(<H3([^>]*)>(.*?)</H3>|<A\s+[^>]*HREF="([^"]*)"[^>]*>(.*?)</A>|<DL>|</DL>)re",
            QRegularExpression::CaseInsensitiveOption | QRegularExpression::DotMatchesEverythingOption);
        QStringList stack;
        QString pending;
        bool pendingSet = false;
        auto unescape = [](QString s) {
            s.remove(QRegularExpression("<[^>]*>"));
            return s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").trimmed();
        };
        auto it = token.globalMatch(text);
        while (it.hasNext()) {
            const auto m = it.next();
            const auto whole = m.captured(0).toUpper();
            if (whole == "<DL>") {
                stack.append(pendingSet ? pending : (stack.isEmpty() ? QString() : stack.last()));
                pendingSet = false;
            } else if (whole == "</DL>") {
                if (!stack.isEmpty())
                    stack.removeLast();
            } else if (!m.captured(2).isNull() && m.captured(0).startsWith("<H3", Qt::CaseInsensitive)) {
                const bool toolbar = m.captured(1).contains("PERSONAL_TOOLBAR_FOLDER", Qt::CaseInsensitive);
                pending = toolbar ? QString() : unescape(m.captured(2));
                pendingSet = true;
            } else if (!m.captured(3).isEmpty()) {
                found.append({stack.isEmpty() ? QString() : stack.last(), {unescape(m.captured(3)), unescape(m.captured(4))}});
            }
        }
    }
    int added = 0;
    for (const auto &item : std::as_const(found)) {
        const auto &url = item.second.first;
        if (url.isEmpty() || url.startsWith("javascript:") || url.startsWith("place:") || isBookmarked(url))
            continue;
        m_bookmarks.append(QJsonObject{{"url", url},
                                       {"title", item.second.second.isEmpty() ? hostOf(url) : item.second.second},
                                       {"folder", item.first},
                                       {"added", double(QDateTime::currentMSecsSinceEpoch())}});
        ++added;
    }
    if (added > 0) {
        ++m_bookmarksRevision;
        schedule("bookmarks");
        emit bookmarksChanged();
    }
    return added;
}

QVariantList Library::importSources() const {
    const auto config = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/";
    const QList<QPair<QString, QString>> candidates{
        {"Google Chrome", "google-chrome/Default/Bookmarks"},
        {"Chromium", "chromium/Default/Bookmarks"},
        {"Brave", "BraveSoftware/Brave-Browser/Default/Bookmarks"},
        {"Vivaldi", "vivaldi/Default/Bookmarks"},
        {"Microsoft Edge", "microsoft-edge/Default/Bookmarks"},
        {"Opera", "opera/Bookmarks"},
        {"Thorium", "thorium/Default/Bookmarks"},
        {"Helium", "net.imput.helium/Default/Bookmarks"},
    };
    QVariantList out;
    for (const auto &c : candidates)
        if (QFileInfo::exists(config + c.second))
            out.append(QVariantMap{{"name", c.first}, {"path", config + c.second}});
    return out;
}

bool Library::exportBookmarks(const QString &rawPath) const {
    const auto path = rawPath.startsWith("file:") ? QUrl(rawPath).toLocalFile() : rawPath;
    auto escape = [](QString s) { return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;"); };
    QString html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n"
                   "<TITLE>Favoris</TITLE>\n<H1>Favoris</H1>\n<DL><p>\n";
    html += "    <DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Barre de favoris</H3>\n    <DL><p>\n";
    for (const auto &v : m_bookmarks) {
        const auto o = v.toObject();
        if (o.value("folder").toString().isEmpty())
            html += QString("        <DT><A HREF=\"%1\" ADD_DATE=\"%2\">%3</A>\n")
                        .arg(escape(o.value("url").toString()))
                        .arg(qint64(o.value("added").toDouble() / 1000))
                        .arg(escape(o.value("title").toString()));
    }
    html += "    </DL><p>\n";
    for (const auto &folder : folders()) {
        html += QString("    <DT><H3>%1</H3>\n    <DL><p>\n").arg(escape(folder));
        for (const auto &v : m_bookmarks) {
            const auto o = v.toObject();
            if (o.value("folder").toString() == folder)
                html += QString("        <DT><A HREF=\"%1\" ADD_DATE=\"%2\">%3</A>\n")
                            .arg(escape(o.value("url").toString()))
                            .arg(qint64(o.value("added").toDouble() / 1000))
                            .arg(escape(o.value("title").toString()));
        }
        html += "    </DL><p>\n";
    }
    html += "</DL><p>\n";
    QSaveFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(html.toUtf8()) >= 0 && file.commit();
}

// ---------------------------------------------------------------- dial

QVariantList Library::dial() const {
    QVariantList out;
    for (int i = 0; i < m_dial.size(); ++i) {
        auto map = m_dial.at(i).toObject().toVariantMap();
        map["index"] = i;
        map["host"] = hostOf(map.value("url").toString());
        out.append(map);
    }
    return out;
}

bool Library::inDial(const QString &url) const {
    for (const auto &v : m_dial)
        if (v.toObject().value("url").toString() == url)
            return true;
    return false;
}

void Library::addDial(const QString &url, const QString &title) {
    if (url.trimmed().isEmpty())
        return;
    m_dial.append(QJsonObject{{"url", url.trimmed()}, {"title", title.trimmed().isEmpty() ? hostOf(url) : title.trimmed()}});
    ++m_dialRevision;
    schedule("dial");
    emit dialChanged();
}

void Library::updateDial(int index, const QString &url, const QString &title) {
    if (index < 0 || index >= m_dial.size())
        return;
    m_dial[index] = QJsonObject{{"url", url.trimmed()}, {"title", title.trimmed().isEmpty() ? hostOf(url) : title.trimmed()}};
    ++m_dialRevision;
    schedule("dial");
    emit dialChanged();
}

void Library::removeDial(int index) {
    if (index < 0 || index >= m_dial.size())
        return;
    m_dial.removeAt(index);
    ++m_dialRevision;
    schedule("dial");
    emit dialChanged();
}

void Library::moveDial(int from, int to) {
    if (from < 0 || from >= m_dial.size() || to < 0 || to >= m_dial.size() || from == to)
        return;
    const auto item = m_dial.at(from);
    m_dial.removeAt(from);
    m_dial.insert(to, item);
    ++m_dialRevision;
    schedule("dial");
    emit dialChanged();
}

// ---------------------------------------------------------------- session

void Library::saveSession(const QVariantList &windows) { save("session", QJsonArray::fromVariantList(windows)); }

QVariantList Library::session() const { return load("session").toVariantList(); }

// ---------------------------------------------------------------- zoom

double Library::zoomFor(const QString &url) const { return m_zoom.value(hostOf(url), 0); }

void Library::setZoom(const QString &url, double factor) {
    const auto host = hostOf(url);
    if (host.isEmpty())
        return;
    if (factor <= 0)
        m_zoom.remove(host);
    else
        m_zoom.insert(host, factor);
    schedule("zoom");
}

// ---------------------------------------------------------------- downloads

void Library::logDownload(const QVariantMap &download) {
    const auto path = download.value("path").toString();
    for (int i = 0; i < m_downloads.size(); ++i)
        if (m_downloads.at(i).toObject().value("path").toString() == path) {
            m_downloads.removeAt(i);
            break;
        }
    auto o = QJsonObject::fromVariantMap(download);
    if (!o.contains("finished"))
        o["finished"] = double(QDateTime::currentMSecsSinceEpoch());
    m_downloads.prepend(o);
    while (m_downloads.size() > kDownloadsCap)
        m_downloads.removeLast();
    ++m_downloadsRevision;
    schedule("downloads");
    emit downloadsChanged();
}

QVariantList Library::downloads() const {
    QVariantList out;
    for (const auto &v : m_downloads) {
        auto map = v.toObject().toVariantMap();
        map["exists"] = QFileInfo::exists(map.value("path").toString());
        out.append(map);
    }
    return out;
}

void Library::removeDownload(const QString &path) {
    for (int i = 0; i < m_downloads.size(); ++i)
        if (m_downloads.at(i).toObject().value("path").toString() == path) {
            m_downloads.removeAt(i);
            ++m_downloadsRevision;
            schedule("downloads");
            emit downloadsChanged();
            return;
        }
}

void Library::clearDownloads() {
    m_downloads = QJsonArray();
    ++m_downloadsRevision;
    schedule("downloads");
    emit downloadsChanged();
}
