#pragma once

#include <QObject>
#include <QVariantList>

class AiClient;
class BrowserSettings;

// The page assistant: summarise, explain or question the page that is open,
// or a selection, with Claude, OpenAI, Gemini or a local model. Answers
// stream in through partial() and end with finished() or failed().
class PageAi : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString provider READ provider NOTIFY providerChanged)

public:
    PageAi(AiClient *client, BrowserSettings *settings, QObject *parent = nullptr);

    bool busy() const { return m_busy; }
    QString provider() const;

    // turns: [{role: "user"|"assistant", text}], the last one is the question.
    Q_INVOKABLE void ask(const QString &id, const QVariantList &turns, const QString &pageTitle, const QString &pageUrl,
                         const QString &pageText, const QString &provider = {});
    Q_INVOKABLE void cancel();
    Q_INVOKABLE bool ready(const QString &provider) const;
    Q_INVOKABLE QString providerName(const QString &provider) const;
    Q_INVOKABLE QString model(const QString &provider) const;
    Q_INVOKABLE void listModels(const QString &provider);

    static QString systemPrompt(const QString &language, const QString &title, const QString &url, const QString &text);

signals:
    void busyChanged();
    void providerChanged();
    void partial(const QString &id, const QString &text);
    void finished(const QString &id, const QString &text);
    void failed(const QString &id, const QString &message);
    void modelsListed(const QString &provider, const QStringList &models, const QString &error);

private:
    AiClient *m_client;
    BrowserSettings *m_settings;
    bool m_busy = false;
    int m_generation = 0;
};
