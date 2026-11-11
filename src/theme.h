#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QHash>
#include <QObject>
#include <QTimer>
#include <QVariantMap>

// Follows the whole Vex palette live, not just the accent, and derives the
// few surface tones the window needs from it.
class Theme : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString accent READ accent NOTIFY changed)
    Q_PROPERTY(QString accentForeground READ accentForeground NOTIFY changed)
    // The colour that marks selection and focus: the accent, unless the accent
    // is close to grey, in which case the palette's most vivid colour.
    Q_PROPERTY(QColor highlight READ highlight NOTIFY changed)
    Q_PROPERTY(QColor highlightText READ highlightText NOTIFY changed)
    Q_PROPERTY(QColor background READ background NOTIFY changed)
    Q_PROPERTY(QColor sidebar READ sidebar NOTIFY changed)
    Q_PROPERTY(QColor surface READ surface NOTIFY changed)
    Q_PROPERTY(QColor raised READ raised NOTIFY changed)
    Q_PROPERTY(QColor line READ line NOTIFY changed)
    Q_PROPERTY(QColor text READ text NOTIFY changed)
    Q_PROPERTY(QColor textDim READ textDim NOTIFY changed)
    Q_PROPERTY(QColor textFaint READ textFaint NOTIFY changed)
    Q_PROPERTY(QColor danger READ danger NOTIFY changed)
    Q_PROPERTY(QColor success READ success NOTIFY changed)
    Q_PROPERTY(QColor warning READ warning NOTIFY changed)
    // "plein", "sombre" or "clair": how the logo wears the accent.
    Q_PROPERTY(QString logoStyle READ logoStyle NOTIFY changed)
    // Light or dark: "auto" follows the Vex theme, "light"/"dark" force it.
    Q_PROPERTY(QString mode READ mode NOTIFY changed)
    Q_PROPERTY(bool isDark READ isDark NOTIFY changed)

public:
    explicit Theme(const QString &currentDirectory = {}, QObject *parent = nullptr);

    QString accent() const { return m_accent; }
    QString accentForeground() const;
    QColor highlight() const;
    QColor highlightText() const;
    QColor background() const;
    // Light mode: a warm paper ground, white cards, a slightly deeper sidebar.
    QColor sidebar() const { return isDark() ? mix(background(), QColor(Qt::black), 0.25) : mix(background(), text(), 0.035); }
    QColor surface() const { return isDark() ? mix(background(), text(), 0.035) : QColor(Qt::white); }
    QColor raised() const { return mix(background(), text(), isDark() ? 0.07 : 0.055); }
    QColor line() const { return mix(background(), text(), isDark() ? 0.10 : 0.09); }
    QColor text() const;
    QColor textDim() const { return mix(text(), background(), isDark() ? 0.38 : 0.40); }
    QColor textFaint() const { return mix(text(), background(), isDark() ? 0.58 : 0.56); }
    QColor danger() const { return readable(color("bright_red", color("red", "#ff6b6b"))); }
    QColor success() const { return readable(color("bright_green", color("green", "#7fcf8a"))); }
    QColor warning() const { return readable(color("bright_yellow", color("yellow", "#e0b050"))); }

    QString mode() const { return m_mode; }
    void setMode(const QString &mode);
    // "accent" (default), "neutral", or a #rrggbb colour for folder icons.
    void setFolderColor(const QString &color);
    bool isDark() const;
    // A palette colour made readable on the current background: light
    // colours are darkened in light mode.
    Q_INVOKABLE QColor readable(const QColor &color) const;

    // Colour for a file category (dossier, image, code…), drawn from the palette.
    Q_INVOKABLE QColor kindColor(const QString &kind) const;
    // A programming language's dot colour for repository rows.
    Q_INVOKABLE QColor languageColor(const QString &language) const;
    Q_INVOKABLE QColor alpha(const QColor &color, double opacity) const;
    // Colour for a syntax role: keyword, string, number, comment, function,
    // type, tag, attribute, constant, heading, preprocessor, operator.
    Q_INVOKABLE QColor syntax(const QString &role) const;

    // A fixed highlight colour chosen in the settings; empty follows the theme.
    void setOverride(const QString &color);
    QString logoStyle() const { return m_logoStyle; }
    void setLogoStyle(const QString &style);
    // {tile, back, front, spark} for "flair", "flaircode" or "flairweb", in a style
    // (empty: the current one).
    Q_INVOKABLE QVariantMap logoColors(const QString &app, const QString &style = {}) const;

    static QString readAccent(const QString &path);
    static QHash<QString, QColor> readColors(const QString &path);
    static QColor mix(const QColor &a, const QColor &b, double amount);
    static QColor mostVivid(const QHash<QString, QColor> &colors, const QColor &fallback);

signals:
    void changed();

private:
    QColor color(const QString &key, const QColor &fallback) const { return m_colors.value(key, fallback); }
    void reload();

    QString m_directory;
    QString m_accent = "#FFD60A";
    QColor m_override;
    QString m_logoStyle = "plein";
    QString m_mode = "auto";
    QString m_folderColor = "accent";
    bool m_vexDark = true;
    QHash<QString, QColor> m_colors;
    QFileSystemWatcher m_watcher;
    QTimer m_debounce;
};
