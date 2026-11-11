#include "shield.h"
#include "dnr.h"

#include "library.h"
#include "settings.h"

#include <QStandardPaths>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocale>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QSaveFile>
#include <QUrl>

namespace {
struct ListSource {
    const char *key;
    const char *name;
    const char *url;
    bool byDefault;
};
const ListSource kLists[] = {
    {"stevenblack", "StevenBlack (pubs et logiciels malveillants)",
     "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", true},
    {"peterlowe", "Peter Lowe (pubs et pistage)",
     "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext", true},
    {"hagezi", "HaGeZi Pro (plus strict)", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.txt",
     false},
    {"social", "Boutons et traceurs des réseaux sociaux",
     "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/social-only/hosts", false},
};
} // namespace

Shield::Shield(BrowserSettings *settings, const QString &directory, QObject *parent)
    : QWebEngineUrlRequestInterceptor(parent),
      m_settings(settings),
      m_directory(directory.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/flairweb/shield" : directory),
      m_network(new QNetworkAccessManager(this)) {
    QDir().mkpath(m_directory);
    m_notify.setSingleShot(true);
    m_notify.setInterval(250);
    connect(&m_notify, &QTimer::timeout, this, [this] {
        for (const auto &host : std::as_const(m_pendingNotify))
            emit blocked(host);
        m_pendingNotify.clear();
        emit blockedChanged();
    });
    connect(m_settings, &BrowserSettings::changed, this, &Shield::reloadSettings);
    reloadSettings();
}

QStringList Shield::builtinDomains() {
    // The usual suspects: ad exchanges, analytics and session recorders.
    return {
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagservices.com", "adservice.google.com", "pagead2.googlesyndication.com", "imasdk.googleapis.com",
        "analytics.google.com", "stats.g.doubleclick.net", "app-measurement.com", "googletagmanager.com",
        "connect.facebook.net", "pixel.facebook.com", "an.facebook.com", "ads.linkedin.com", "px.ads.linkedin.com",
        "snap.licdn.com", "analytics.tiktok.com", "ads.tiktok.com", "ads-api.tiktok.com", "ads-twitter.com",
        "static.ads-twitter.com", "analytics.twitter.com", "bat.bing.com", "clarity.ms",
        "scorecardresearch.com", "quantserve.com", "quantcount.com", "taboola.com", "outbrain.com", "outbrainimg.com",
        "criteo.com", "criteo.net", "adnxs.com", "adsrvr.org", "amazon-adsystem.com", "aax.amazon-adsystem.com",
        "moatads.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com", "smartadserver.com",
        "teads.tv", "yieldmo.com", "sharethrough.com", "bidswitch.net", "3lift.com", "adform.net", "adformdsp.net",
        "chartbeat.com", "chartbeat.net", "hotjar.com", "hotjar.io", "mouseflow.com", "fullstory.com",
        "crazyegg.com", "luckyorange.com", "mixpanel.com", "heapanalytics.com", "segment.io", "cdn.segment.com",
        "api.segment.io", "amplitude.com", "api.amplitude.com", "newrelic.com", "nr-data.net", "adroll.com",
        "mgid.com", "revcontent.com", "zemanta.com", "popads.net", "propellerads.com", "exoclick.com",
        "juicyads.com", "trafficjunky.net", "adsafeprotected.com", "doubleverify.com", "mc.yandex.ru",
        "an.yandex.ru", "yandexadexchange.net", "adfox.ru", "media.net", "contextual.media.net", "serving-sys.com",
        "sizmek.com", "rlcdn.com", "bluekai.com", "krxd.net", "demdex.net", "omtrdc.net", "everesttech.net",
        "agkn.com", "tapad.com", "adsymptotic.com", "mathtag.com", "turn.com", "lijit.com", "sovrn.com",
        "indexww.com", "districtm.io", "gumgum.com", "33across.com", "onetag-sys.com", "seedtag.com", "smaato.net",
        "inmobi.com", "unityads.unity3d.com", "applovin.com", "adcolony.com", "vungle.com", "chartboost.com",
        "ironsrc.com", "app.adjust.com", "appsflyer.com", "kochava.com", "onesignal.com",
        "pushwoosh.com", "pushcrew.com", "sumo.com", "addthis.com", "sharethis.com", "disqusads.com",
        "zergnet.com", "yieldlab.net", "adition.com", "weborama.fr", "weborama.com", "xiti.com", "ati-host.net",
        "at-o.net", "eulerian.net", "cxense.com", "permutive.com", "permutive.app",
        "id5-sync.com", "liveramp.com", "lotame.com", "crwdcntrl.net", "eyeota.net", "bounceexchange.com",
        "wunderkind.co", "optimizely.com", "cdn.optimizely.com", "kameleoon.eu", "abtasty.com", "contentsquare.net",
        "clicktale.net", "quantummetric.com", "glassboxdigital.io", "sessioncam.com", "inspectlet.com",
        "smartlook.com", "ad.doubleclick.net", "securepubads.g.doubleclick.net", "adsystem.com",
        "adtech.com", "advertising.com", "atdmt.com", "rfihub.com", "ipredictive.com", "adentifi.com",
        "bidr.io", "dotomi.com", "emxdgt.com", "gammaplatform.com", "lkqd.net", "springserve.com", "spotxchange.com",
        "spotx.tv", "stickyadstv.com", "tremorhub.com", "videohub.tv", "innovid.com", "flashtalking.com",
        "ad-score.com", "adscore.com", "iasds01.com", "nativeads.com", "adblade.com",
        "content.ad", "revjet.com", "bttrack.com", "dianomi.com", "plista.com", "ligatus.com", "adyoulike.com",
    };
}

bool Shield::isPrivateHost(const QString &host) {
    if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".lan"))
        return true;
    QHostAddress address;
    if (!address.setAddress(host))
        return false;
    return address.isLoopback() || address.isPrivateUse() || address.isLinkLocal();
}

QStringList Shield::parseHostsFile(const QByteArray &bytes) {
    QStringList out;
    for (auto line : bytes.split('\n')) {
        const int hash = line.indexOf('#');
        if (hash >= 0)
            line.truncate(hash);
        line = line.trimmed();
        if (line.isEmpty() || line.startsWith('!') || line.startsWith('['))
            continue;
        const auto parts = line.simplified().split(' ');
        QByteArray domain = parts.size() >= 2 ? parts.at(1) : parts.at(0);
        // Adblock-style "||example.com^" lines carry a domain too.
        if (domain.startsWith("||"))
            domain = domain.mid(2);
        if (domain.endsWith('^'))
            domain.chop(1);
        domain = domain.toLower();
        if (domain.isEmpty() || domain == "localhost" || domain == "localhost.localdomain" || domain == "local" ||
            domain == "broadcasthost" || domain == "0.0.0.0" || domain.contains('/') || domain.contains('*') ||
            !domain.contains('.') || domain == "ip6-localhost" || domain == "ip6-loopback")
            continue;
        out.append(QString::fromUtf8(domain));
    }
    return out;
}

QString Shield::listPath(const QString &key) const { return m_directory + "/" + key + ".txt"; }

QVariantList Shield::lists() const {
    const auto enabled = m_settings->value("privacy/lists").toString();
    QVariantList out;
    for (const auto &l : kLists) {
        const bool on = enabled.isEmpty() ? l.byDefault : enabled.split(',').contains(l.key);
        const QFileInfo file(listPath(l.key));
        out.append(QVariantMap{{"key", l.key},
                               {"name", l.name},
                               {"url", l.url},
                               {"enabled", on},
                               {"downloaded", file.exists()},
                               {"updated", file.exists() ? QLocale().toString(file.lastModified(), QLocale::ShortFormat) : QString()}});
    }
    return out;
}

void Shield::setListEnabled(const QString &key, bool enabled) {
    QStringList keys;
    for (const auto &l : lists()) {
        const auto map = l.toMap();
        const bool on = map.value("key") == key ? enabled : map.value("enabled").toBool();
        if (on)
            keys.append(map.value("key").toString());
    }
    // Never empty once touched, so "nothing" stays nothing.
    m_settings->set("privacy/lists", keys.isEmpty() ? QString("none") : keys.join(','));
    if (enabled && !QFileInfo::exists(listPath(key)))
        updateLists();
}

void Shield::loadDownloaded() {
    QDateTime newest;
    for (const auto &l : lists()) {
        const auto map = l.toMap();
        if (!map.value("enabled").toBool())
            continue;
        QFile file(listPath(map.value("key").toString()));
        if (!file.open(QIODevice::ReadOnly))
            continue;
        for (const auto &d : parseHostsFile(file.readAll()))
            m_domains.insert(d);
        const auto modified = QFileInfo(file).lastModified();
        if (!newest.isValid() || modified > newest)
            newest = modified;
    }
    m_listUpdated = newest.isValid() ? QLocale().toString(newest, QLocale::ShortFormat) : QString();
}

void Shield::reloadSettings() {
    m_enabled = m_settings->value("privacy/shield").toBool();
    m_dnt = m_settings->value("privacy/dnt").toBool();
    m_httpsUpgrade = m_settings->value("privacy/httpsUpgrade").toBool();
    const auto signature = m_settings->value("privacy/blocked").toString() + "|" +
                           m_settings->value("privacy/lists").toString() + "|" + QString::number(m_revision);
    m_allowedSites.clear();
    for (const auto &line : m_settings->value("privacy/allowed").toString().split('\n', Qt::SkipEmptyParts)) {
        auto host = line.trimmed().toLower();
        if (host.startsWith("www."))
            host = host.mid(4);
        if (!host.isEmpty())
            m_allowedSites.insert(host);
    }
    if (signature == m_signature) {
        emit changed();
        return;
    }
    m_signature = signature;
    m_domains.clear();
    for (const auto &d : builtinDomains())
        m_domains.insert(d);
    loadDownloaded();
    for (const auto &line : m_settings->value("privacy/blocked").toString().split('\n', Qt::SkipEmptyParts)) {
        const auto d = line.trimmed().toLower();
        if (!d.isEmpty() && !d.startsWith('#'))
            m_domains.insert(d);
    }
    emit changed();
}

void Shield::updateLists() {
    if (m_updating > 0)
        return;
    m_status = "Téléchargement des listes…";
    for (const auto &l : lists()) {
        const auto map = l.toMap();
        if (!map.value("enabled").toBool())
            continue;
        ++m_updating;
        QNetworkRequest request(QUrl(map.value("url").toString()));
        request.setTransferTimeout(30000);
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        auto *reply = m_network->get(request);
        const auto key = map.value("key").toString();
        connect(reply, &QNetworkReply::finished, this, [this, reply, key] {
            reply->deleteLater();
            const auto bytes = reply->readAll();
            if (reply->error() == QNetworkReply::NoError && parseHostsFile(bytes).size() > 10) {
                QSaveFile file(listPath(key));
                if (file.open(QIODevice::WriteOnly)) {
                    file.write(bytes);
                    file.commit();
                }
            } else {
                m_status = "Une liste n'a pas pu être téléchargée : " + reply->errorString();
            }
            if (--m_updating == 0) {
                ++m_revision; // forces the merge in reloadSettings
                reloadSettings();
                if (m_status.startsWith("Téléchargement"))
                    m_status = QString("%1 domaines bloqués.").arg(QLocale().toString(m_domains.size()));
            }
            emit changed();
        });
    }
    if (m_updating == 0)
        m_status = "Aucune liste choisie.";
    emit changed();
}

bool Shield::shouldBlock(const QString &rawHost, const QString &firstPartyHost) const {
    QString host = rawHost.toLower();
    // The site's own subdomains (example.com loading static.example.com) are
    // first party and stay allowed.
    if (host.isEmpty() || host == firstPartyHost || (!firstPartyHost.isEmpty() && host.endsWith("." + firstPartyHost)))
        return false;
    for (;;) {
        if (m_domains.contains(host))
            return true;
        const int dot = host.indexOf('.');
        if (dot < 0)
            return false;
        host = host.mid(dot + 1);
        if (!host.contains('.'))
            return false;
    }
}

static QString siteOf(const QString &host) {
    auto h = host.toLower();
    if (h.startsWith("www."))
        h = h.mid(4);
    return h;
}

void Shield::intercept(QWebEngineUrlRequestInfo &info, bool withExtensions) {
    const auto url = info.requestUrl();
    const auto firstParty = siteOf(info.firstPartyUrl().host(QUrl::FullyEncoded));
    const bool mainFrame = info.resourceType() == QWebEngineUrlRequestInfo::ResourceTypeMainFrame;

    if (m_dnt) {
        info.setHttpHeader("DNT", "1");
        info.setHttpHeader("Sec-GPC", "1");
    }
    static const bool requestLog = qEnvironmentVariableIsSet("FLAIRWEB_REQLOG");
    if (requestLog)
        qInfo().noquote() << "[req]" << info.resourceType() << info.initiator().toString() << url.toString().left(300);
    if (m_dnr && withExtensions) {
        const auto outcome = m_dnr->evaluate(url, info.initiator(), info.firstPartyUrl(), info.resourceType(), info.requestMethod());
        if (Dnr::apply(outcome, info)) {
            if (outcome.block && !mainFrame)
                countBlocked(firstParty, url.host(QUrl::FullyEncoded));
            static const bool trace = qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG");
            if (trace)
                qInfo().noquote() << "[dnr]" << (outcome.block ? "block" : "redirect") << outcome.rulesetId << outcome.ruleId << url.toString().left(100);
            return;
        }
    }
    if (m_httpsUpgrade && url.scheme() == "http" && !isPrivateHost(url.host(QUrl::FullyEncoded)) &&
        !m_httpOnlyHosts.contains(url.host(QUrl::FullyEncoded)) && !m_allowedSites.contains(siteOf(url.host(QUrl::FullyEncoded))) &&
        !m_allowedSites.contains(firstParty)) {
        if (mainFrame)
            m_upgradedHosts.insert(url.host(QUrl::FullyEncoded));
        QUrl secure(url);
        secure.setScheme("https");
        if (secure.port() == 80)
            secure.setPort(-1);
        info.redirect(secure);
        return;
    }
    if (mainFrame) {
        // A new page: its count starts over.
        const auto site = siteOf(url.host(QUrl::FullyEncoded));
        if (m_blockedBySite.remove(site) > 0) {
            m_pendingNotify.insert(site);
            m_notify.start();
        }
        return;
    }
    if (!m_enabled || url.scheme() == "data" || url.scheme() == "blob" || url.scheme() == "chrome-extension")
        return;
    if (m_allowedSites.contains(firstParty))
        return;
    if (!shouldBlock(url.host(QUrl::FullyEncoded), firstParty))
        return;
    info.block(true);
    countBlocked(firstParty, url.host(QUrl::FullyEncoded));
}

void Shield::countBlocked(const QString &firstParty, const QString &host) {
    // Counts per host: a page left open for days stays small.
    m_blockedBySite[firstParty][host]++;
    ++m_total;
    m_pendingNotify.insert(firstParty);
    if (!m_notify.isActive())
        m_notify.start();
}

bool Shield::upgradeFailed(const QString &url) {
    const QUrl u(url);
    if (u.scheme() != "https" || !m_upgradedHosts.contains(u.host(QUrl::FullyEncoded)))
        return false;
    m_upgradedHosts.remove(u.host(QUrl::FullyEncoded));
    m_httpOnlyHosts.insert(u.host(QUrl::FullyEncoded));
    return true;
}

int Shield::blockedOn(const QString &pageUrl) const {
    int total = 0;
    for (const int n : m_blockedBySite.value(siteOf(QUrl(pageUrl).host(QUrl::FullyEncoded))))
        total += n;
    return total;
}

QStringList Shield::blockedHostsOn(const QString &pageUrl) const {
    const auto counts = m_blockedBySite.value(siteOf(QUrl(pageUrl).host(QUrl::FullyEncoded)));
    // Most blocked first.
    QStringList hosts = counts.keys();
    std::sort(hosts.begin(), hosts.end(), [&counts](const QString &a, const QString &b) { return counts[a] > counts[b]; });
    QStringList out;
    for (const auto &h : hosts)
        out.append(QString("%1  ×%2").arg(h).arg(counts[h]));
    return out;
}

bool Shield::isAllowed(const QString &pageUrl) const { return m_allowedSites.contains(siteOf(QUrl(pageUrl).host(QUrl::FullyEncoded))); }

void Shield::setAllowed(const QString &pageUrl, bool allowed) {
    const auto site = siteOf(QUrl(pageUrl).host(QUrl::FullyEncoded));
    if (site.isEmpty())
        return;
    auto lines = m_settings->value("privacy/allowed").toString().split('\n', Qt::SkipEmptyParts);
    for (auto &l : lines)
        l = l.trimmed();
    lines.removeAll(site);
    if (allowed)
        lines.append(site);
    m_settings->set("privacy/allowed", lines.join('\n'));
}
