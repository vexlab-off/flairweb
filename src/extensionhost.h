#pragma once

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QTimer>
#include <QVariant>

class Dnr;
class QTcpServer;
class QTcpSocket;

// What makes real Chrome extensions work in Flair Web. Qt WebEngine only
// gives them runtime, storage, alarms and a few more; the rest of the
// chrome.* API (tabs, windows, action, contextMenus, scripting,
// webNavigation, permissions, declarativeNetRequest…) is provided by a
// bridge script added to each extension at install time, which talks to
// this host over a local WebSocket (127.0.0.1, checked by the extension's
// origin and a secret). Calls the browser has to answer (tabs, menus…) go
// to QML through call(); events come back with emitEvent().
class ExtensionHost : public QObject {
    Q_OBJECT
    Q_PROPERTY(int port READ port CONSTANT)

public:
    ExtensionHost(Dnr *dnr, const QString &dataDir, QObject *parent = nullptr);

    bool listen();
    int port() const { return m_port; }

    // ---- Preparing an extension (a copy, never the user's folder)
    // Unpacks a .zip into a fresh folder named after the extension, adds the
    // bridge, and returns the folder ("" on failure).
    QString prepareZip(const QByteArray &zip, const QString &name, QString *error, const QByteArray &publicKey = {});
    QString prepareFolder(const QString &source, QString *error);
    // Adds or refreshes the bridge in an extension folder; true if it changed.
    bool patch(const QString &dir, QString *error = nullptr, const QByteArray &publicKey = {});
    // For an installed extension: patches it when its bridge is missing or
    // older than this Flair Web. True when it changed (active after restart).
    bool ensurePatched(const QString &dir);
    static QString patchCsp(const QString &csp);
    static QString injectScripts(const QString &original);

    void setExtensionPath(const QString &id, const QString &path) { m_paths.insert(id, path); }

    // ---- For QML
    Q_INVOKABLE void reply(int callId, const QVariant &result, const QString &error = QString());
    // Sends an event to every context of an extension ("" = all extensions).
    Q_INVOKABLE void emitEvent(const QString &extension, const QString &name, const QVariantList &args);
    // A module the content bridge can import: "export default <source>".
    Q_INVOKABLE QString registerCode(const QString &source);
    // Extensions with a live context (their bridge is connected).
    Q_INVOKABLE QStringList connected() const;
    // Where the content bridge loads an extension's files from.
    Q_INVOKABLE QString fileBase(const QString &extension) const;

signals:
    void call(int callId, const QString &extension, const QString &method, const QVariantList &args,
              const QVariantMap &context);

private:
    struct Client {
        QPointer<QTcpSocket> socket;
        QByteArray buffer;
        bool websocket = false;
        QString extension;
        QString kind;
        QString url;
        QByteArray message;
        int messageOpcode = 0;
    };
    struct Pending {
        QPointer<QTcpSocket> socket;
        QVariant id;
    };

    void onReadable(QTcpSocket *socket);
    void handleHttp(Client &client, const QByteArray &head, const QByteArray &body);
    void handleFrames(Client &client);
    void handleMessage(Client &client, const QByteArray &text);
    void sendText(QTcpSocket *socket, const QByteArray &text);
    void sendHttp(QTcpSocket *socket, int status, const QByteArray &type, const QByteArray &body,
                  const QByteArray &origin = "*");
    QString secret() const { return m_secret; }
    QList<int> candidatePorts() const;

    Dnr *m_dnr;
    QString m_dataDir;
    QString m_secret;
    QString m_fileKey;
    QTcpServer *m_server = nullptr;
    int m_port = 0;
    QHash<QTcpSocket *, Client> m_clients;
    QHash<int, Pending> m_pending;
    int m_nextCall = 1;
    QHash<QString, QPair<QByteArray, qint64>> m_code;
    QHash<QString, QString> m_paths;
    QTimer m_keepAlive;
};
