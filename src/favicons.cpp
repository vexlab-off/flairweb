#include "favicons.h"

#include "library.h"

#include <QStandardPaths>
#include <QDir>
#include <QFileInfo>
#include <QImage>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>

Favicons::Favicons(const QString &directory, QObject *parent)
    : QObject(parent),
      m_directory(directory.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) + "/flairweb/favicons" : directory),
      m_network(new QNetworkAccessManager(this)) {
    QDir().mkpath(m_directory);
}

QString Favicons::pathFor(const QString &host) const {
    // The ASCII form: two Unicode names never share a file.
    QString safe = QString::fromLatin1(QUrl::toAce(host));
    if (safe.isEmpty())
        safe = host;
    safe.replace(QRegularExpression("[^a-z0-9.\\-]"), "_");
    return m_directory + "/" + safe + ".png";
}

QString Favicons::forUrl(const QString &pageUrl) {
    const QUrl url(pageUrl);
    if (url.scheme() != "http" && url.scheme() != "https")
        return {};
    const auto host = Library::hostOf(pageUrl);
    if (host.isEmpty())
        return {};
    const auto path = pathFor(host);
    if (QFileInfo::exists(path))
        return QUrl::fromLocalFile(path).toString();
    if (!m_tried.contains(host)) {
        m_tried.insert(host);
        fetch(host, QUrl(url.scheme() + "://" + url.host() + "/favicon.ico"), true);
    }
    return {};
}

void Favicons::remember(const QString &pageUrl, const QString &viewIcon) {
    static const QString prefix = "image://favicon/";
    if (!viewIcon.startsWith(prefix))
        return;
    const auto host = Library::hostOf(pageUrl);
    const QUrl icon(viewIcon.mid(prefix.size()));
    if (host.isEmpty() || !icon.isValid() || (icon.scheme() != "http" && icon.scheme() != "https"))
        return;
    // Once per icon address per session; the file is refreshed when it changes.
    if (m_rememberedIcon.value(host) == icon.toString())
        return;
    m_rememberedIcon.insert(host, icon.toString());
    m_tried.insert(host);
    fetch(host, icon, false);
}

void Favicons::fetch(const QString &host, const QUrl &iconUrl, bool fallbackToPage) {
    QNetworkRequest request(iconUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader, "Mozilla/5.0 (X11; Linux x86_64) FlairWeb/0.1");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(6000);
    auto *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, host, iconUrl, fallbackToPage] {
        reply->deleteLater();
        QImage image;
        const bool ok = reply->error() == QNetworkReply::NoError && image.loadFromData(reply->readAll()) && !image.isNull();
        if (!ok) {
            // No /favicon.ico: the icon the home page declares.
            if (fallbackToPage)
                fetchFromPage(host, QUrl(iconUrl.scheme() + "://" + iconUrl.host() + "/"));
            return;
        }
        if (image.width() > 64 || image.height() > 64)
            image = image.scaled(64, 64, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        if (image.save(pathFor(host), "PNG")) {
            ++m_revision;
            emit changed();
        }
    });
}

QUrl Favicons::iconInPage(const QByteArray &html, const QUrl &base) {
    // The <link rel="icon"> (or apple-touch-icon) with the best size, SVG
    // excepted (QImage can't read it without the svg plugin's help).
    static const QRegularExpression link(R"(<link\b[^>]*>)", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression rel(R"(\brel\s*=\s*["']?([^"'>]+))", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression href(R"(\bhref\s*=\s*["']?([^"' >]+))", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression sizes(R"(\bsizes\s*=\s*["']?(\d+)x)", QRegularExpression::CaseInsensitiveOption);
    const auto text = QString::fromUtf8(html.left(256 * 1024));
    QUrl best;
    int bestScore = -1;
    for (auto it = link.globalMatch(text); it.hasNext();) {
        const auto tag = it.next().captured(0);
        const auto r = rel.match(tag).captured(1).toLower();
        const auto h = href.match(tag).captured(1);
        if (!r.contains("icon") || r.contains("mask-icon") || h.isEmpty())
            continue;
        const auto url = base.resolved(QUrl(QString(h).replace("&amp;", "&")));
        if (url.path().endsWith(".svg", Qt::CaseInsensitive) || (url.scheme() != "http" && url.scheme() != "https"))
            continue;
        const int size = sizes.match(tag).hasMatch() ? sizes.match(tag).captured(1).toInt() : 16;
        // Close to 64 px is best; touch icons only when nothing else.
        const int score = (r.contains("apple") ? 0 : 1000) + (size >= 32 ? 500 - qAbs(size - 64) : size);
        if (score > bestScore) {
            bestScore = score;
            best = url;
        }
    }
    return best;
}

void Favicons::fetchFromPage(const QString &host, const QUrl &pageUrl) {
    QNetworkRequest request(pageUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader, "Mozilla/5.0 (X11; Linux x86_64) FlairWeb/0.1");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(6000);
    auto *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, host] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError)
            return;
        const auto icon = iconInPage(reply->readAll(), reply->url());
        if (icon.isValid())
            fetch(host, icon, false);
    });
}

void Favicons::clear() {
    QDir dir(m_directory);
    for (const auto &file : dir.entryList({"*.png"}, QDir::Files))
        dir.remove(file);
    m_tried.clear();
    m_rememberedIcon.clear();
    ++m_revision;
    emit changed();
}
