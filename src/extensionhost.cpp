#include "extensionhost.h"
#include "dnr.h"

#include <QBuffer>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QJsonArray>
#include <QLocale>
#include <QMimeDatabase>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QUrlQuery>
#include <private/qzipreader_p.h>
#include <unistd.h>

namespace {

// Bumped when bridge.js or content.js change: installed extensions get the
// new copy at the next start.
constexpr int kBridgeVersion = 2;
const char *const kScripts = R"(<script src="/flair/config.js"></script><script src="/flair/messages.js"></script><script src="/flair/bridge.js"></script>)";

QString randomKey() {
    QByteArray bytes(24, Qt::Uninitialized);
    QRandomGenerator::system()->fillRange(reinterpret_cast<quint32 *>(bytes.data()), bytes.size() / 4);
    return QString::fromLatin1(bytes.toHex());
}

bool writeFile(const QString &path, const QByteArray &data) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(data) == data.size() && file.commit();
}

QByteArray readFile(const QString &path) {
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
}

bool copyTree(const QString &from, const QString &to) {
    QDir source(from);
    if (!source.exists())
        return false;
    QDirIterator it(from, QDir::Files | QDir::Hidden | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const auto file = it.next();
        const auto target = to + "/" + source.relativeFilePath(file);
        QDir().mkpath(QFileInfo(target).absolutePath());
        QFile::remove(target);
        if (!QFile::copy(file, target))
            return false;
    }
    return true;
}

} // namespace

ExtensionHost::ExtensionHost(Dnr *dnr, const QString &dataDir, QObject *parent)
    : QObject(parent), m_dnr(dnr), m_dataDir(dataDir), m_fileKey(randomKey()) {
    // Surrogate scripts (uBlock's neutered gpt.js…) come from here.
    m_dnr->setFileUrl([this](const QString &extension, const QString &path) {
        return QUrl(fileBase(extension) + QString(path).remove(QRegularExpression("^/+")));
    });
    // One secret per profile, written into each prepared extension.
    const auto secretFile = dataDir + "/extensions.secret";
    m_secret = QString::fromLatin1(readFile(secretFile)).trimmed();
    if (m_secret.size() < 32) {
        m_secret = randomKey();
        writeFile(secretFile, m_secret.toLatin1());
        QFile::setPermissions(secretFile, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    }
    // Service workers stop when idle; a message every 20 s keeps the ones
    // connected to us alive, as Chrome does for extensions with a socket.
    m_keepAlive.setInterval(20000);
    connect(&m_keepAlive, &QTimer::timeout, this, [this] {
        const auto now = QDateTime::currentSecsSinceEpoch();
        for (auto it = m_code.begin(); it != m_code.end();)
            it = now - it->second > 600 ? m_code.erase(it) : std::next(it);
        for (auto &client : m_clients)
            if (client.websocket && client.socket)
                sendText(client.socket, R"({"ka":1})");
    });
    m_keepAlive.start();
}

QList<int> ExtensionHost::candidatePorts() const {
    // Stable per user, so extensions prepared once keep finding us.
    const int base = 41000 + int(getuid() % 400) * 10;
    return {base, base + 1, base + 2, base + 3, base + 4};
}

// The user owning the other end of a loopback TCP connection, read from
// /proc/net/tcp (-1 when unknown). Other users on the machine can reach
// 127.0.0.1 too: they must never talk to the bridge.
static long peerUid(quint16 peerPort, quint16 localPort) {
    for (const char *table : {"/proc/net/tcp", "/proc/net/tcp6"}) {
        QFile file(table);
        if (!file.open(QIODevice::ReadOnly))
            continue;
        // /proc files have no size: read them whole, then line by line.
        const auto lines = file.readAll().split('\n');
        for (int i = 1; i < lines.size(); ++i) {
            const auto fields = lines.at(i).simplified().split(' ');
            if (fields.size() < 8)
                continue;
            // The client's own socket: local = its port, remote = ours.
            const auto local = fields.at(1), remote = fields.at(2);
            bool ok1 = false, ok2 = false;
            const auto lp = local.mid(local.lastIndexOf(':') + 1).toUInt(&ok1, 16);
            const auto rp = remote.mid(remote.lastIndexOf(':') + 1).toUInt(&ok2, 16);
            if (ok1 && ok2 && lp == peerPort && rp == localPort)
                return fields.at(7).toLong();
        }
    }
    return -1;
}

bool ExtensionHost::listen() {
    m_server = new QTcpServer(this);
    for (int port : candidatePorts())
        if (m_server->listen(QHostAddress::LocalHost, quint16(port))) {
            m_port = port;
            break;
        }
    if (!m_port)
        return false;
    connect(m_server, &QTcpServer::newConnection, this, [this] {
        while (auto *socket = m_server->nextPendingConnection()) {
            const long uid = peerUid(socket->peerPort(), socket->localPort());
            if (uid != long(getuid())) {
                if (qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG"))
                    qInfo().noquote() << "[ext refuse] connection from uid" << uid;
                socket->abort();
                socket->deleteLater();
                continue;
            }
            Client client;
            client.socket = socket;
            m_clients.insert(socket, client);
            connect(socket, &QTcpSocket::readyRead, this, [this, socket] { onReadable(socket); });
            connect(socket, &QTcpSocket::disconnected, this, [this, socket] {
                m_clients.remove(socket);
                socket->deleteLater();
            });
        }
    });
    return true;
}

// ---------------------------------------------------------------- preparing extensions

QString ExtensionHost::patchCsp(const QString &csp) {
    const QString ours = "http://127.0.0.1:* ws://127.0.0.1:*";
    auto directives = csp.split(';', Qt::SkipEmptyParts);
    QString defaults;
    bool found = false;
    for (auto &d : directives) {
        const auto t = d.trimmed();
        if (t.startsWith("connect-src")) {
            found = true;
            if (!t.contains("127.0.0.1"))
                d = t.contains("'none'") ? "connect-src " + ours : t + " " + ours;
        } else if (t.startsWith("default-src")) {
            defaults = t.mid(11).trimmed();
        }
    }
    if (!found && !defaults.isEmpty())
        directives.append(" connect-src " + (defaults.contains("'none'") ? QString() : defaults + " ") + ours);
    for (auto &d : directives)
        d = d.trimmed();
    return directives.join("; ");
}

QString ExtensionHost::injectScripts(const QString &original) {
    // An older Flair Web's scripts make way for the current ones.
    static const QRegularExpression ours(R"(<script src="/flair/[a-z]+\.js"></script>)");
    QString html = original;
    html.remove(ours);
    static const QRegularExpression head("<head\\b[^>]*>", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression root("<html\\b[^>]*>", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression doctype("<!doctype[^>]*>", QRegularExpression::CaseInsensitiveOption);
    for (const auto *re : {&head, &root, &doctype}) {
        const auto m = re->match(html);
        if (m.hasMatch())
            return html.left(m.capturedEnd()) + kScripts + html.mid(m.capturedEnd());
    }
    return kScripts + html;
}

bool ExtensionHost::patch(const QString &dir, QString *error, const QByteArray &publicKey) {
    const auto manifestPath = dir + "/manifest.json";
    auto manifest = QJsonDocument::fromJson(readFile(manifestPath)).object();
    if (manifest.isEmpty()) {
        if (error)
            *error = "manifest.json introuvable ou illisible";
        return false;
    }
    if (manifest.value("manifest_version").toInt() != 3) {
        if (error)
            *error = "seules les extensions Manifest V3 fonctionnent avec Qt WebEngine";
        return false;
    }
    auto state = QJsonDocument::fromJson(readFile(dir + "/flair/patch.json")).object();
    // The Web Store's id comes from the key the .crx was signed with.
    if (!publicKey.isEmpty() && !manifest.contains("key"))
        manifest.insert("key", QString::fromLatin1(publicKey.toBase64()));

    // Background: the bridge loads first, then the extension's own worker.
    auto background = manifest.value("background").toObject();
    QString worker = state.value("worker").toString();
    if (worker.isEmpty()) {
        worker = background.value("service_worker").toString();
        if (worker.startsWith("flair/") || worker.endsWith("flair-worker.js"))
            worker.clear();
    }
    // A worker path leading outside the folder is not followed.
    if (!worker.isEmpty() && (QDir::cleanPath(QString(worker).remove(QRegularExpression("^/+"))).startsWith("..") ||
                              QDir::isAbsolutePath(QDir::cleanPath(QString(worker).remove(QRegularExpression("^/+")))))) {
        if (error)
            *error = "chemin du service worker hors de l'extension";
        return false;
    }
    if (!worker.isEmpty()) {
        const auto relative = QString(worker).remove(QRegularExpression("^/+"));
        const auto path = "/" + relative;
        // Next to the extension's own worker: scripts it loads by relative
        // path (webpack chunks…) resolve as they would without us.
        const int slash = relative.lastIndexOf('/');
        const auto wrapperPath = (slash >= 0 ? relative.left(slash + 1) : QString()) + "flair-worker.js";
        const bool module = background.value("type").toString() == "module";
        const auto wrapper = module ? QString("import \"/flair/config.js\";\nimport \"/flair/messages.js\";\nimport \"/flair/bridge.js\";\nimport \"%1\";\n").arg(path)
                                    : QString("importScripts(\"/flair/config.js\", \"/flair/messages.js\", \"/flair/bridge.js\", \"%1\");\n").arg(path);
        writeFile(dir + "/" + wrapperPath, wrapper.toUtf8());
        QFile::remove(dir + "/flair/worker.js");
        background.insert("service_worker", wrapperPath);
        manifest.insert("background", background);
        state.insert("worker", worker);
    }

    // Content scripts: the content bridge runs first in every frame.
    QJsonArray scripts;
    scripts.append(QJsonObject{{"matches", QJsonArray{"<all_urls>"}},
                               {"js", QJsonArray{"flair/messages.js", "flair/content.js"}},
                               {"run_at", "document_start"},
                               {"all_frames", true},
                               {"match_about_blank", true}});
    for (const auto &v : manifest.value("content_scripts").toArray())
        if (!v.toObject().value("js").toArray().contains(QJsonValue("flair/content.js")))
            scripts.append(v);
    manifest.insert("content_scripts", scripts);

    // Extension pages may talk to 127.0.0.1.
    auto csp = manifest.value("content_security_policy").toObject();
    if (csp.contains("extension_pages")) {
        csp.insert("extension_pages", patchCsp(csp.value("extension_pages").toString()));
        manifest.insert("content_security_policy", csp);
    }

    // Every page of the extension gets the bridge before its own scripts.
    QDirIterator pages(dir, {"*.html", "*.htm"}, QDir::Files, QDirIterator::Subdirectories);
    while (pages.hasNext()) {
        const auto file = pages.next();
        if (file.startsWith(dir + "/flair/"))
            continue;
        const auto html = QString::fromUtf8(readFile(file));
        const auto patched = injectScripts(html);
        if (patched != html)
            writeFile(file, patched.toUtf8());
    }

    // Files changed: the Web Store's signatures no longer apply.
    QDir(dir + "/_metadata").removeRecursively();

    const auto config = QString("globalThis.__flairBridge = {ports: [%1], token: \"%2\", version: %3};\n")
                            .arg([this] {
                                QStringList list;
                                for (int p : candidatePorts())
                                    list.append(QString::number(p));
                                return list.join(", ");
                            }(),
                                 m_secret)
                            .arg(kBridgeVersion);
    // Messages for chrome.i18n: the default locale, then the system's.
    QJsonObject messages;
    const auto defaultLocale = manifest.value("default_locale").toString();
    if (!defaultLocale.isEmpty()) {
        QStringList locales{defaultLocale};
        const auto system = QLocale::system().name();
        locales << system.left(system.indexOf('_')) << system;
        for (const auto &locale : locales) {
            const auto catalog = QJsonDocument::fromJson(readFile(dir + "/_locales/" + locale + "/messages.json")).object();
            for (auto it = catalog.begin(); it != catalog.end(); ++it)
                messages.insert(it.key().toLower(), it.value());
        }
    }
    const auto messagesJs = "globalThis.__flairMessages = " + QJsonDocument(messages).toJson(QJsonDocument::Compact) +
                            ";\nglobalThis.__flairLocale = \"" + QLocale::system().name().toLatin1() + "\";\n" +
                            readFile(":/extension/i18n.js");
    state.insert("version", kBridgeVersion);
    const bool ok = writeFile(dir + "/flair/config.js", config.toUtf8()) &&
                    writeFile(dir + "/flair/bridge.js", readFile(":/extension/bridge.js")) &&
                    writeFile(dir + "/flair/content.js", readFile(":/extension/content.js")) &&
                    writeFile(dir + "/flair/keepalive.html", "<!doctype html><meta charset=\"utf-8\"><script src=\"keepalive.js\"></script>\n") &&
                    writeFile(dir + "/flair/keepalive.js", readFile(":/extension/keepalive.js")) &&
                    writeFile(dir + "/flair/messages.js", messagesJs) &&
                    writeFile(dir + "/flair/patch.json", QJsonDocument(state).toJson()) &&
                    writeFile(manifestPath, QJsonDocument(manifest).toJson());
    // The bridge's settings hold the secret: for this user only.
    QFile::setPermissions(dir + "/flair/config.js", QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    if (!ok && error)
        *error = "impossible d'écrire dans " + dir;
    return ok;
}

bool ExtensionHost::ensurePatched(const QString &dir) {
    const auto state = QJsonDocument::fromJson(readFile(dir + "/flair/patch.json")).object();
    const auto config = readFile(dir + "/flair/config.js");
    if (state.value("version").toInt() == kBridgeVersion && config.contains(m_secret.toLatin1()) &&
        readFile(dir + "/flair/bridge.js") == readFile(":/extension/bridge.js") &&
        readFile(dir + "/flair/content.js") == readFile(":/extension/content.js") &&
        readFile(dir + "/flair/keepalive.js") == readFile(":/extension/keepalive.js") &&
        readFile(dir + "/flair/messages.js").endsWith(readFile(":/extension/i18n.js")) &&
        !QFile::exists(dir + "/flair/worker.js"))
        return false;
    return patch(dir);
}

QString ExtensionHost::prepareZip(const QByteArray &zip, const QString &name, QString *error, const QByteArray &publicKey) {
    const auto dir = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) + "/flairweb/extensions/" + name;
    QDir(dir).removeRecursively();
    QDir().mkpath(dir);
    QBuffer buffer;
    buffer.setData(zip);
    buffer.open(QIODevice::ReadOnly);
    QZipReader reader(&buffer);
    if (!reader.isReadable() || reader.status() != QZipReader::NoError) {
        *error = "archive illisible";
        return {};
    }
    // Each entry is checked to stay inside the folder.
    const QDir root(dir);
    const auto entries = reader.fileInfoList();
    // An archive that unpacks to something huge is refused before it fills memory.
    qint64 total = 0;
    for (const auto &info : entries)
        total += info.size;
    if (entries.size() > 50000 || total > 512LL * 1024 * 1024) {
        *error = "archive trop grande";
        return {};
    }
    // Folders, also when the archive doesn't mark them as such.
    QSet<QString> folders;
    for (const auto &info : entries) {
        const auto parts = QString(info.filePath).split('/', Qt::SkipEmptyParts);
        for (int i = 1; i < parts.size(); ++i)
            folders.insert(parts.mid(0, i).join('/'));
    }
    for (const auto &info : entries) {
        const auto target = QDir::cleanPath(root.absoluteFilePath(info.filePath));
        if (!target.startsWith(root.absolutePath() + "/")) {
            *error = "chemin suspect dans l'archive : " + info.filePath;
            return {};
        }
        const auto clean = QString(info.filePath).remove(QRegularExpression("/+$"));
        if (info.isDir || info.filePath.endsWith('/') || folders.contains(clean))
            QDir().mkpath(target);
        else if (!info.isSymLink && !writeFile(target, reader.fileData(info.filePath))) {
            *error = "impossible d'extraire " + info.filePath;
            return {};
        }
    }
    // Some archives hold a single folder with the extension inside.
    QString base = dir;
    if (!QFile::exists(dir + "/manifest.json")) {
        const auto subdirs = QDir(dir).entryList(QDir::Dirs | QDir::NoDotAndDotDot);
        if (subdirs.size() == 1 && QFile::exists(dir + "/" + subdirs.first() + "/manifest.json"))
            base = dir + "/" + subdirs.first();
    }
    return patch(base, error, publicKey) ? base : QString();
}

QString ExtensionHost::prepareFolder(const QString &source, QString *error) {
    const auto dir = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) + "/flairweb/extensions/" +
                     QFileInfo(source).fileName();
    QDir(dir).removeRecursively();
    if (!copyTree(source, dir)) {
        *error = "copie impossible de " + source;
        return {};
    }
    return patch(dir, error) ? dir : QString();
}

// ---------------------------------------------------------------- the local server

void ExtensionHost::onReadable(QTcpSocket *socket) {
    auto it = m_clients.find(socket);
    if (it == m_clients.end())
        return;
    Client &client = *it;
    client.buffer += socket->readAll();
    if (client.websocket) {
        handleFrames(client);
        return;
    }
    const int end = client.buffer.indexOf("\r\n\r\n");
    if (end < 0) {
        if (client.buffer.size() > 65536)
            socket->abort();
        return;
    }
    const auto head = client.buffer.left(end);
    static const QRegularExpression lengthRe("\r\ncontent-length:\\s*(\\d+)", QRegularExpression::CaseInsensitiveOption);
    const auto m = lengthRe.match(QString::fromLatin1(head));
    const qint64 length = m.hasMatch() ? m.captured(1).toLongLong() : 0;
    // Requests here are small: a huge body is refused, not buffered.
    if (length < 0 || length > 1024 * 1024) {
        socket->abort();
        return;
    }
    if (client.buffer.size() < end + 4 + length)
        return;
    const auto body = client.buffer.mid(end + 4, length);
    client.buffer.remove(0, end + 4 + length);
    handleHttp(client, head, body);
}

void ExtensionHost::sendHttp(QTcpSocket *socket, int status, const QByteArray &type, const QByteArray &body,
                             const QByteArray &origin) {
    const QByteArray reason = status == 200 ? "OK" : status == 204 ? "No Content" : status == 403 ? "Forbidden" : "Not Found";
    QByteArray out = "HTTP/1.1 " + QByteArray::number(status) + " " + reason + "\r\n";
    out += "Content-Type: " + type + "\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n";
    // Only extensions' pages may read the answers from another origin.
    if (origin.startsWith("chrome-extension://"))
        out += "Access-Control-Allow-Origin: " + origin + "\r\n";
    out += "Access-Control-Allow-Private-Network: true\r\nAccess-Control-Allow-Headers: *\r\n";
    out += "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + body;
    socket->write(out);
    socket->disconnectFromHost();
}

void ExtensionHost::handleHttp(Client &client, const QByteArray &head, const QByteArray &body) {
    Q_UNUSED(body)
    QTcpSocket *socket = client.socket;
    const auto lines = head.split('\n');
    const auto request = lines.value(0).trimmed().split(' ');
    const auto method = request.value(0);
    const QUrl url("http://127.0.0.1" + QString::fromLatin1(request.value(1)));
    QHash<QByteArray, QByteArray> headers;
    for (int i = 1; i < lines.size(); ++i) {
        const int colon = lines[i].indexOf(':');
        if (colon > 0)
            headers.insert(lines[i].left(colon).trimmed().toLower(), lines[i].mid(colon + 1).trimmed());
    }
    const auto origin = headers.value("origin");

    if (method == "OPTIONS") {
        sendHttp(socket, 204, "text/plain", {}, origin);
        return;
    }
    const auto path = url.path();

    // The bridge of an extension page or worker.
    if (path == "/ws" && headers.value("upgrade").toLower() == "websocket") {
        const QUrlQuery query(url);
        const auto extension = query.queryItemValue("ext");
        const auto token = query.queryItemValue("token");
        if (token != m_secret || extension.isEmpty() || !m_paths.contains(extension) ||
            origin != "chrome-extension://" + extension.toLatin1()) {
            sendHttp(socket, 403, "text/plain", "forbidden");
            return;
        }
        const auto accept = QCryptographicHash::hash(headers.value("sec-websocket-key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
                                                     QCryptographicHash::Sha1)
                                .toBase64();
        socket->write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      "Sec-WebSocket-Accept: " + accept + "\r\n\r\n");
        client.websocket = true;
        client.extension = extension;
        client.kind = query.queryItemValue("kind");
        client.url = query.queryItemValue("url", QUrl::FullyDecoded);
        if (qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG")) {
            qInfo().noquote() << "[ext connect]" << extension.left(8) << client.kind << client.url;
            sendText(socket, R"({"ev":"__trace"})");
        }
        if (!client.buffer.isEmpty())
            handleFrames(client);
        return;
    }
    // Code for the content bridge to import (scripting.executeScript).
    if (path.startsWith("/m/")) {
        const auto key = path.mid(3).chopped(path.endsWith(".js") ? 3 : 0);
        const auto it = m_code.constFind(key);
        if (it == m_code.constEnd()) {
            sendHttp(socket, 404, "text/plain", "gone");
            return;
        }
        sendHttp(socket, 200, "text/javascript; charset=utf-8", it->first);
        return;
    }
    // An extension's own file, as a module (scripting with files).
    if (path.startsWith("/f/" + m_fileKey + "/")) {
        const auto rest = path.mid(4 + m_fileKey.size());
        const int slash = rest.indexOf('/');
        const auto root = m_paths.value(rest.left(slash));
        // The bridge's own files (its secret among them) are never served.
        if (slash > 0 && (rest.mid(slash + 1).startsWith("flair/") || QUrlQuery(url).queryItemValue("files", QUrl::FullyDecoded).contains("flair/"))) {
            sendHttp(socket, 404, "text/plain", "not found");
            return;
        }
        // Several files in one module, as Chrome runs them in one world.
        const auto files = QUrlQuery(url).queryItemValue("files", QUrl::FullyDecoded);
        if (slash > 0 && !root.isEmpty() && !files.isEmpty()) {
            QByteArray all;
            for (const auto &name : files.split(',', Qt::SkipEmptyParts)) {
                const auto file = QDir::cleanPath(root + "/" + name);
                if (!file.startsWith(QDir::cleanPath(root) + "/") || !QFileInfo(file).isFile()) {
                    sendHttp(socket, 404, "text/plain", "not found");
                    return;
                }
                all += readFile(file) + "\n;\n";
            }
            sendHttp(socket, 200, "text/javascript; charset=utf-8", all);
            return;
        }
        if (slash > 0 && !root.isEmpty()) {
            const auto file = QDir::cleanPath(root + "/" + rest.mid(slash + 1));
            if (file.startsWith(QDir::cleanPath(root) + "/") && QFileInfo(file).isFile()) {
                static const QMimeDatabase mimes;
                auto type = mimes.mimeTypeForFile(file, QMimeDatabase::MatchExtension).name().toLatin1();
                if (file.endsWith(".js") || file.endsWith(".mjs"))
                    type = "text/javascript";
                if (type.startsWith("text/"))
                    type += "; charset=utf-8";
                sendHttp(socket, 200, type, readFile(file));
                return;
            }
        }
    }
    sendHttp(socket, 404, "text/plain", "not found");
}

void ExtensionHost::handleFrames(Client &client) {
    auto &b = client.buffer;
    while (b.size() >= 2) {
        const quint8 b0 = quint8(b[0]), b1 = quint8(b[1]);
        const bool fin = b0 & 0x80;
        const int opcode = b0 & 0x0f;
        const bool masked = b1 & 0x80;
        qint64 length = b1 & 0x7f;
        int offset = 2;
        if (length == 126) {
            if (b.size() < 4)
                return;
            length = (quint8(b[2]) << 8) | quint8(b[3]);
            offset = 4;
        } else if (length == 127) {
            if (b.size() < 10)
                return;
            length = 0;
            for (int i = 0; i < 8; ++i)
                length = (length << 8) | quint8(b[2 + i]);
            offset = 10;
        }
        if (length < 0 || length > 64 * 1024 * 1024) {
            client.socket->abort();
            return;
        }
        const int maskOffset = offset;
        if (masked)
            offset += 4;
        if (b.size() < offset + length)
            return;
        QByteArray payload = b.mid(offset, length);
        if (masked)
            for (int i = 0; i < payload.size(); ++i)
                payload[i] = char(payload[i] ^ b[maskOffset + (i % 4)]);
        b.remove(0, offset + length);

        if (opcode == 0x8) {             // close
            client.socket->write(QByteArray("\x88\x00", 2));
            client.socket->disconnectFromHost();
            return;
        }
        if (opcode == 0x9) {             // ping
            QByteArray pong;
            pong.append(char(0x8a));
            pong.append(char(payload.size()));
            client.socket->write(pong + payload.left(125));
            continue;
        }
        if (opcode == 0xa)
            continue;
        if (opcode == 0x1 || opcode == 0x2) {
            client.message = payload;
            client.messageOpcode = opcode;
        } else if (opcode == 0x0) {
            client.message += payload;
            if (client.message.size() > 64 * 1024 * 1024) {
                client.socket->abort();
                return;
            }
        }
        if (fin) {
            const auto text = client.message;
            client.message.clear();
            handleMessage(client, text);
            if (!m_clients.contains(client.socket))
                return;
        }
    }
}

void ExtensionHost::sendText(QTcpSocket *socket, const QByteArray &text) {
    if (!socket || socket->state() != QAbstractSocket::ConnectedState)
        return;
    QByteArray frame;
    frame.append(char(0x81));
    if (text.size() < 126) {
        frame.append(char(text.size()));
    } else if (text.size() < 65536) {
        frame.append(char(126));
        frame.append(char((text.size() >> 8) & 0xff));
        frame.append(char(text.size() & 0xff));
    } else {
        frame.append(char(127));
        const quint64 n = quint64(text.size());
        for (int i = 7; i >= 0; --i)
            frame.append(char((n >> (8 * i)) & 0xff));
    }
    socket->write(frame + text);
}

void ExtensionHost::handleMessage(Client &client, const QByteArray &text) {
    const auto message = QJsonDocument::fromJson(text).object();
    const auto id = message.value("i").toVariant();
    const auto method = message.value("m").toString();
    const auto args = message.value("a").toArray().toVariantList();
    static const bool trace = qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG");
    if (trace)
        qInfo().noquote() << "[ext]" << client.extension.left(8) << client.kind << method
                          << QJsonDocument(message.value("a").toArray()).toJson(QJsonDocument::Compact).left(160);
    QPointer<QTcpSocket> socket = client.socket;
    auto answer = [this, socket, id](const QVariant &result, const QString &error) {
        QJsonObject out{{"i", QJsonValue::fromVariant(id)}};
        if (!error.isEmpty())
            out.insert("e", error);
        else
            out.insert("r", QJsonValue::fromVariant(result));
        sendText(socket, QJsonDocument(out).toJson(QJsonDocument::Compact));
    };

    if (method.startsWith("declarativeNetRequest.")) {
        QString error;
        const auto result = m_dnr->call(client.extension, method.mid(22), args, &error);
        answer(result, error);
        return;
    }
    if (method == "flair.log") {
        QStringList parts;
        for (const auto &a : args)
            parts.append(a.toString());
        qInfo().noquote() << "[ext log]" << client.extension.left(8) << client.kind << parts.join(' ').left(600);
        answer({}, {});
        return;
    }
    if (method == "flair.code") {
        answer(registerCode(args.value(0).toString()), {});
        return;
    }
    if (method == "flair.fileBase") {
        answer(fileBase(client.extension), {});
        return;
    }
    const int callId = m_nextCall++;
    m_pending.insert(callId, {socket, id});
    emit call(callId, client.extension, method, args,
              QVariantMap{{"kind", client.kind}, {"url", client.url}});
}

void ExtensionHost::reply(int callId, const QVariant &result, const QString &error) {
    const auto pending = m_pending.take(callId);
    if (qEnvironmentVariableIsSet("FLAIRWEB_EXTLOG"))
        qInfo().noquote() << "[ext reply]" << (error.isEmpty() ? QJsonDocument::fromVariant(QVariantList{result}).toJson(QJsonDocument::Compact).left(200) : "error: " + error.toUtf8());
    if (!pending.socket)
        return;
    QJsonObject out{{"i", QJsonValue::fromVariant(pending.id)}};
    if (!error.isEmpty())
        out.insert("e", error);
    else
        out.insert("r", QJsonValue::fromVariant(result));
    sendText(pending.socket, QJsonDocument(out).toJson(QJsonDocument::Compact));
}

void ExtensionHost::emitEvent(const QString &extension, const QString &name, const QVariantList &args) {
    const auto text = QJsonDocument(QJsonObject{{"ev", name}, {"a", QJsonArray::fromVariantList(args)}}).toJson(QJsonDocument::Compact);
    for (auto &client : m_clients)
        if (client.websocket && (extension.isEmpty() || client.extension == extension))
            sendText(client.socket, text);
}

QString ExtensionHost::registerCode(const QString &source) {
    const auto key = randomKey();
    m_code.insert(key, {"export default " + source.toUtf8() + ";\n", QDateTime::currentSecsSinceEpoch()});
    return QString("http://127.0.0.1:%1/m/%2.js").arg(m_port).arg(key);
}

QString ExtensionHost::fileBase(const QString &extension) const {
    return QString("http://127.0.0.1:%1/f/%2/%3/").arg(m_port).arg(m_fileKey, extension);
}

QStringList ExtensionHost::connected() const {
    QStringList out;
    for (const auto &client : m_clients)
        if (client.websocket && !out.contains(client.extension))
            out.append(client.extension);
    return out;
}
