#include "ai.h"

#include "settings.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSharedPointer>
#include <QUrlQuery>

static const char *kAnthropicVersion = "2026-10-21";

AiClient::AiClient(BrowserSettings *settings, QObject *parent)
    : QObject(parent), m_settings(settings), m_network(new QNetworkAccessManager(this)) {}

QString AiClient::providerName(const QString &provider) {
    if (provider == "claude")
        return "Claude";
    if (provider == "openai")
        return "OpenAI";
    if (provider == "gemini")
        return "Gemini";
    return tr("Local");
}

QString AiClient::modelFor(const QString &provider) const {
    if (provider == "claude")
        return m_settings->value("ai/claudeModel").toString();
    if (provider == "openai")
        return m_settings->value("ai/openaiModel").toString();
    if (provider == "gemini")
        return m_settings->value("ai/geminiModel").toString();
    return m_settings->value("ai/localModel").toString();
}

bool AiClient::ready(const QString &provider) const {
    if (provider == "local")
        return !m_settings->value("ai/localUrl").toString().isEmpty();
    return !m_settings->apiKey(provider).isEmpty();
}

void AiClient::cancelAll() {
    const auto replies = m_replies;
    m_replies.clear();
    for (const auto &reply : replies) {
        if (reply) {
            reply->setProperty("cancelled", true);
            reply->abort();
        }
    }
}

// ---------------------------------------------------------------- decoding

QString AiClient::claudeText(const QByteArray &payload, QString *error) {
    const auto event = QJsonDocument::fromJson(payload).object();
    const auto type = event.value("type").toString();
    if (type == "content_block_delta") {
        const auto delta = event.value("delta").toObject();
        if (delta.value("type").toString() == "text_delta")
            return delta.value("text").toString();
    } else if (type == "message_delta") {
        if (event.value("delta").toObject().value("stop_reason").toString() == "refusal" && error)
            *error = tr("Claude a refusé de répondre à cette demande.");
    } else if (type == "error" && error) {
        *error = tr("Erreur Claude : %1").arg(event.value("error").toObject().value("message").toString());
    }
    return {};
}

QString AiClient::openAiText(const QByteArray &payload, QString *error) {
    if (payload == "[DONE]")
        return {};
    const auto event = QJsonDocument::fromJson(payload).object();
    if (event.contains("error") && error) {
        const auto e = event.value("error");
        *error = e.isObject() ? e.toObject().value("message").toString() : e.toString();
        return {};
    }
    const auto choices = event.value("choices").toArray();
    return choices.isEmpty() ? QString() : choices.first().toObject().value("delta").toObject().value("content").toString();
}

QString AiClient::geminiText(const QByteArray &payload, QString *error) {
    const auto event = QJsonDocument::fromJson(payload).object();
    if (event.contains("error") && error) {
        *error = tr("Erreur Gemini : %1").arg(event.value("error").toObject().value("message").toString());
        return {};
    }
    QString text;
    for (const auto &candidate : event.value("candidates").toArray()) {
        const auto c = candidate.toObject();
        for (const auto &part : c.value("content").toObject().value("parts").toArray())
            text += part.toObject().value("text").toString();
        if (c.value("finishReason").toString() == "SAFETY" && error)
            *error = tr("Gemini a bloqué cette réponse (filtre de sécurité).");
    }
    return text;
}

QJsonArray AiClient::geminiContents(const Turns &turns) {
    QJsonArray contents;
    for (const auto &turn : turns)
        contents.append(QJsonObject{{"role", turn.first == "assistant" ? "model" : "user"},
                                    {"parts", QJsonArray{QJsonObject{{"text", turn.second}}}}});
    return contents;
}

// Reasoning models put their scratchpad in <think> tags; nobody needs it.
static QString stripThinking(const QString &text) {
    static const QRegularExpression closed(R"(<think>.*?</think>)", QRegularExpression::DotMatchesEverythingOption);
    static const QRegularExpression open(R"(<think>.*$)", QRegularExpression::DotMatchesEverythingOption);
    QString out = text;
    out.remove(closed);
    out.remove(open);
    return out.trimmed();
}

QString AiClient::httpError(const QString &provider, int status, const QByteArray &body, const QString &network) const {
    const auto name = providerName(provider);
    if (status == 0) {
        if (provider == "local")
            return tr("Le serveur local ne répond pas sur %1. Lance LM Studio (Developer → Start Server) ou Ollama.")
                .arg(m_settings->value("ai/localUrl").toString());
        return tr("Impossible de joindre %1 : %2").arg(name, network);
    }
    if (status == 401 || status == 403)
        return tr("Clé API %1 refusée (%2). Vérifie-la dans les réglages (Ctrl+,).").arg(name).arg(status);
    if (status == 429)
        return tr("%1 limite les requêtes ou le quota est épuisé (429). Réessaie dans un moment.").arg(name);
    QString detail;
    const auto e = QJsonDocument::fromJson(body).object().value("error");
    if (e.isObject())
        detail = e.toObject().value("message").toString();
    else if (e.isString())
        detail = e.toString();
    if (detail.isEmpty())
        detail = QString::fromUtf8(body.left(300)).trimmed();
    if (status == 404)
        return tr("%1 ne connaît pas ce modèle (404) : %2. Choisis-en un dans les réglages.").arg(name, detail);
    return tr("%1 a répondu %2 : %3").arg(name).arg(status).arg(detail);
}

// ---------------------------------------------------------------- requests

void AiClient::stream(const QString &provider, const QString &system, const Turns &turns, int maxTokens,
                      Progress progress, Done done, Fail fail) {
    const auto model = modelFor(provider);
    const auto key = m_settings->apiKey(provider);
    if (provider != "local" && key.isEmpty()) {
        fail(tr("Aucune clé API %1. Ajoute-la dans les réglages (Ctrl+, → IA) ou exporte %2.")
                 .arg(providerName(provider), BrowserSettings::environmentVariableFor(provider)));
        return;
    }
    if (provider != "local" && model.isEmpty()) {
        fail(tr("Aucun modèle %1 choisi. Dans les réglages (Ctrl+, → IA), clique « Charger les modèles ».")
                 .arg(providerName(provider)));
        return;
    }

    QNetworkRequest request;
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setTransferTimeout(300000);
    QJsonObject body;

    if (provider == "claude") {
        request.setUrl(QUrl("https://api.anthropic.com/v1/messages"));
        request.setRawHeader("x-api-key", key.toUtf8());
        request.setRawHeader("anthropic-version", kAnthropicVersion);
        QJsonArray messages;
        for (const auto &t : turns)
            messages.append(QJsonObject{{"role", t.first}, {"content", t.second}});
        body = {{"model", model}, {"max_tokens", maxTokens}, {"stream", true}, {"system", system},
                {"messages", messages}, {"output_config", QJsonObject{{"effort", "medium"}}}};
        // On a safety decline the API retries on a fallback model in the same call.
        static const QStringList withFallbacks{"claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5",
                                               "claude-opus-5", "claude-sonnet-5-5"};
        if (withFallbacks.contains(model)) {
            body["fallbacks"] = "default";
            request.setRawHeader("anthropic-beta", "server-side-fallback-2026-07-01");
        }
    } else if (provider == "gemini") {
        QUrl url("https://generativelanguage.googleapis.com/v1beta/models/" + model + ":streamGenerateContent");
        url.setQuery("alt=sse");
        request.setUrl(url);
        request.setRawHeader("x-goog-api-key", key.toUtf8());
        body = {{"systemInstruction", QJsonObject{{"parts", QJsonArray{QJsonObject{{"text", system}}}}}},
                {"contents", geminiContents(turns)},
                {"generationConfig", QJsonObject{{"maxOutputTokens", maxTokens}}}};
    } else {
        // OpenAI, and local servers that speak its chat completions format.
        const auto base = provider == "openai" ? QString("https://api.openai.com")
                                               : m_settings->value("ai/localUrl").toString();
        request.setUrl(QUrl(base + "/v1/chat/completions"));
        if (provider == "openai")
            request.setRawHeader("Authorization", "Bearer " + key.toUtf8());
        QJsonArray messages{QJsonObject{{"role", "system"}, {"content", system}}};
        for (const auto &t : turns)
            messages.append(QJsonObject{{"role", t.first}, {"content", t.second}});
        body = {{"messages", messages}, {"stream", true}};
        if (!model.isEmpty())
            body["model"] = model;
        if (provider == "local")
            body["max_tokens"] = maxTokens;
    }

    auto *reply = m_network->post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    start(reply, provider, progress, done, fail);
}

void AiClient::start(QNetworkReply *reply, const QString &provider, Progress progress, Done done, Fail fail) {
    m_replies.removeAll(nullptr);
    m_replies.append(reply);
    auto buffer = QSharedPointer<QByteArray>::create();
    auto full = QSharedPointer<QString>::create();
    auto failure = QSharedPointer<QString>::create();
    auto errorBody = QSharedPointer<QByteArray>::create();

    connect(reply, &QNetworkReply::readyRead, this, [=] {
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto bytes = reply->readAll();
        if (status >= 400) {
            *errorBody += bytes;
            return;
        }
        *buffer += bytes;
        bool grew = false;
        int newline;
        while ((newline = buffer->indexOf('\n')) >= 0) {
            QByteArray line = buffer->left(newline).trimmed();
            buffer->remove(0, newline + 1);
            if (!line.startsWith("data:"))
                continue;
            const auto payload = line.mid(5).trimmed();
            QString error;
            const auto text = provider == "claude" ? claudeText(payload, &error)
                              : provider == "gemini" ? geminiText(payload, &error)
                                                     : openAiText(payload, &error);
            if (!error.isEmpty())
                *failure = error;
            if (!text.isEmpty()) {
                *full += text;
                grew = true;
            }
        }
        if (grew && progress)
            progress(stripThinking(*full));
    });

    connect(reply, &QNetworkReply::finished, this, [=] {
        reply->deleteLater();
        m_replies.removeAll(reply);
        if (reply->property("cancelled").toBool())
            return;
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        *errorBody += reply->readAll();
        if (reply->error() != QNetworkReply::NoError || status >= 400) {
            fail(httpError(provider, status, *errorBody, reply->errorString()));
            return;
        }
        if (!failure->isEmpty()) {
            fail(*failure);
            return;
        }
        done(stripThinking(*full));
    });
}

void AiClient::listModels(const QString &provider, std::function<void(const QStringList &, const QString &)> done) {
    const auto key = m_settings->apiKey(provider);
    if (provider != "local" && key.isEmpty()) {
        done({}, tr("Ajoute d'abord la clé API %1.").arg(providerName(provider)));
        return;
    }
    QNetworkRequest request;
    request.setTransferTimeout(15000);
    if (provider == "claude") {
        request.setUrl(QUrl("https://api.anthropic.com/v1/models?limit=100"));
        request.setRawHeader("x-api-key", key.toUtf8());
        request.setRawHeader("anthropic-version", kAnthropicVersion);
    } else if (provider == "gemini") {
        request.setUrl(QUrl("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200"));
        request.setRawHeader("x-goog-api-key", key.toUtf8());
    } else if (provider == "openai") {
        request.setUrl(QUrl("https://api.openai.com/v1/models"));
        request.setRawHeader("Authorization", "Bearer " + key.toUtf8());
    } else {
        request.setUrl(QUrl(m_settings->value("ai/localUrl").toString() + "/v1/models"));
    }
    auto *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [=] {
        reply->deleteLater();
        const auto bytes = reply->readAll();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError) {
            done({}, httpError(provider, status, bytes, reply->errorString()));
            return;
        }
        const auto json = QJsonDocument::fromJson(bytes).object();
        QStringList models;
        if (provider == "gemini") {
            for (const auto &m : json.value("models").toArray()) {
                const auto o = m.toObject();
                const auto methods = o.value("supportedGenerationMethods").toArray();
                if (methods.contains("generateContent"))
                    models << o.value("name").toString().remove("models/");
            }
        } else {
            for (const auto &m : json.value("data").toArray()) {
                const auto id = m.toObject().value("id").toString();
                // Keep chat models: drop embeddings, audio, image and moderation ones.
                static const QRegularExpression notChat("embed|whisper|tts|dall-e|moderation|image|audio|realtime|transcribe");
                if (!id.contains(notChat))
                    models << id;
            }
        }
        models.sort();
        done(models, {});
    });
}
