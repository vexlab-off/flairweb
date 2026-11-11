#pragma once

#include <QJsonArray>
#include <QList>
#include <QObject>
#include <QPair>
#include <QPointer>
#include <functional>

class BrowserSettings;
class QNetworkAccessManager;
class QNetworkReply;

// Streams answers from Claude, OpenAI, Gemini, or a local OpenAI-compatible
// server (LM Studio, Ollama). Each provider has its own wire format; callers
// only see text growing and a sentence when something fails.
class AiClient : public QObject {
    Q_OBJECT

public:
    using Turns = QList<QPair<QString, QString>>; // (role "user"/"assistant", text)
    using Progress = std::function<void(const QString &soFar)>;
    using Done = std::function<void(const QString &text)>;
    using Fail = std::function<void(const QString &message)>;

    explicit AiClient(BrowserSettings *settings, QObject *parent = nullptr);

    void stream(const QString &provider, const QString &system, const Turns &turns, int maxTokens, Progress progress,
                Done done, Fail fail);
    void listModels(const QString &provider, std::function<void(const QStringList &, const QString &error)> done);
    void cancelAll();

    // Which providers can be called right now (a key, or a local server URL).
    bool ready(const QString &provider) const;
    QString modelFor(const QString &provider) const;
    static QString providerName(const QString &provider);

    // Per-format SSE event decoding, public for tests.
    static QString claudeText(const QByteArray &payload, QString *error);
    static QString openAiText(const QByteArray &payload, QString *error);
    static QString geminiText(const QByteArray &payload, QString *error);
    static QJsonArray geminiContents(const Turns &turns);

private:
    void start(QNetworkReply *reply, const QString &provider, Progress progress, Done done, Fail fail);
    QString httpError(const QString &provider, int status, const QByteArray &body, const QString &network) const;

    BrowserSettings *m_settings;
    QNetworkAccessManager *m_network;
    QList<QPointer<QNetworkReply>> m_replies;
};
