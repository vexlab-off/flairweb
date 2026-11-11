#include "pageai.h"

#include "ai.h"
#include "settings.h"

PageAi::PageAi(AiClient *client, BrowserSettings *settings, QObject *parent)
    : QObject(parent), m_client(client), m_settings(settings) {
    connect(m_settings, &BrowserSettings::changed, this, &PageAi::providerChanged);
}

QString PageAi::provider() const { return m_settings->value("ai/provider").toString(); }
bool PageAi::ready(const QString &provider) const { return m_client->ready(provider); }
QString PageAi::providerName(const QString &provider) const { return AiClient::providerName(provider); }
QString PageAi::model(const QString &provider) const { return m_client->modelFor(provider); }

QString PageAi::systemPrompt(const QString &language, const QString &title, const QString &url, const QString &text) {
    const auto lang = language == "en" ? QString("English") : QString("français");
    QString prompt = QString(
        "Tu es l'assistant de Flair Web, le navigateur de la suite flair. Tu aides à comprendre la page ouverte : "
        "résumer, expliquer, extraire, traduire, comparer. Réponds en %1, en Markdown, de façon concise et "
        "structurée (titres courts, listes). Appuie-toi d'abord sur le contenu de la page ; si la réponse n'y est "
        "pas, dis-le avant d'utiliser tes propres connaissances. Ne prétends pas avoir visité d'autres pages.")
                         .arg(lang);
    if (!url.isEmpty() || !text.isEmpty())
        prompt += QString("\n\n<page>\n<titre>%1</titre>\n<adresse>%2</adresse>\n<contenu>\n%3\n</contenu>\n</page>")
                      .arg(title, url, text);
    return prompt;
}

void PageAi::ask(const QString &id, const QVariantList &turns, const QString &pageTitle, const QString &pageUrl,
                 const QString &pageText, const QString &providerIn) {
    const auto chosen = providerIn.isEmpty() ? provider() : providerIn;
    AiClient::Turns list;
    for (const auto &t : turns) {
        const auto map = t.toMap();
        const auto text = map.value("text").toString();
        if (text.trimmed().isEmpty())
            continue;
        list.append({map.value("role").toString() == "assistant" ? "assistant" : "user", text});
    }
    if (list.isEmpty()) {
        emit failed(id, "Rien à demander.");
        return;
    }
    const int limit = std::max(4000, m_settings->value("ai/pageChars").toInt());
    const auto text = pageText.size() > limit ? pageText.left(limit) + "\n[…page tronquée…]" : pageText;
    const auto system = systemPrompt(m_settings->value("ai/language").toString(), pageTitle, pageUrl, text);
    // A new question replaces the one still being answered (its callbacks,
    // a generation behind, are ignored).
    const int generation = ++m_generation;
    m_client->cancelAll();
    m_busy = true;
    emit busyChanged();
    auto end = [this, generation] {
        if (generation != m_generation)
            return;
        m_busy = false;
        emit busyChanged();
    };
    m_client->stream(
        chosen, system, list, 4096,
        [this, id, generation](const QString &soFar) {
            if (generation == m_generation)
                emit partial(id, soFar);
        },
        [this, id, end, generation](const QString &full) {
            if (generation == m_generation)
                emit finished(id, full);
            end();
        },
        [this, id, end, generation](const QString &message) {
            if (generation == m_generation)
                emit failed(id, message);
            end();
        });
}

void PageAi::cancel() {
    ++m_generation;
    m_client->cancelAll();
    if (m_busy) {
        m_busy = false;
        emit busyChanged();
    }
}

void PageAi::listModels(const QString &provider) {
    m_client->listModels(provider, [this, provider](const QStringList &models, const QString &error) {
        emit modelsListed(provider, models, error);
    });
}
