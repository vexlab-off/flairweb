// Theme watching follows Korcut (MIT, David Heinemeier Hansson).
#include "theme.h"

#include "launcher.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <cmath>

Theme::Theme(const QString &directory, QObject *parent)
    : QObject(parent),
      m_directory(directory.isEmpty() ? QDir::homePath() + "/.local/state/vex/current" : directory) {
    m_debounce.setSingleShot(true);
    m_debounce.setInterval(80);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] { m_debounce.start(); });
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this] { m_debounce.start(); });
    connect(&m_debounce, &QTimer::timeout, this, &Theme::reload);
    reload();
}

QString Theme::readAccent(const QString &path) {
    const auto colors = readColors(path);
    return colors.contains("accent") ? colors.value("accent").name() : QString("#FFD60A");
}

QHash<QString, QColor> Theme::readColors(const QString &path) {
    QHash<QString, QColor> colors;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return colors;
    static const QRegularExpression line(R"re(^\s*([a-z_]+)\s*=\s*["'](#[0-9a-fA-F]{6})["'])re",
                                         QRegularExpression::MultilineOption);
    auto it = line.globalMatch(QString::fromUtf8(file.readAll()));
    while (it.hasNext()) {
        const auto match = it.next();
        colors.insert(match.captured(1), QColor(match.captured(2)));
    }
    return colors;
}

QColor Theme::mix(const QColor &a, const QColor &b, double t) {
    return QColor::fromRgbF(float(a.redF() + (b.redF() - a.redF()) * t), float(a.greenF() + (b.greenF() - a.greenF()) * t),
                            float(a.blueF() + (b.blueF() - a.blueF()) * t));
}

QColor Theme::mostVivid(const QHash<QString, QColor> &colors, const QColor &fallback) {
    // Prefer the cool hues a file manager's selection usually wears, then
    // anything else, judged by HSL saturation weighted by usable lightness.
    static const QStringList order{"bright_blue", "blue", "bright_cyan", "cyan", "bright_magenta", "magenta",
                                   "bright_green", "green"};
    QColor best = fallback;
    double bestScore = 0;
    for (int i = 0; i < order.size(); ++i) {
        const auto c = colors.value(order[i]);
        if (!c.isValid())
            continue;
        const double l = c.lightnessF();
        const double score = c.hslSaturationF() * (1 - std::abs(l - 0.6)) - i * 0.01;
        if (score > bestScore) {
            bestScore = score;
            best = c;
        }
    }
    return best;
}

QString Theme::accentForeground() const {
    const QColor c(m_accent);
    auto linear = [](double v) { return v <= .04045 ? v / 12.92 : std::pow((v + .055) / 1.055, 2.4); };
    const double luminance = .2126 * linear(c.redF()) + .7152 * linear(c.greenF()) + .0722 * linear(c.blueF());
    return luminance > .179 ? "black" : "white";
}

void Theme::setOverride(const QString &color) {
    const QColor next = color == "theme" ? QColor() : QColor(color);
    if (next == m_override)
        return;
    m_override = next;
    emit changed();
}

void Theme::setMode(const QString &mode) {
    const QString next = mode == "light" || mode == "dark" ? mode : QString("auto");
    if (next == m_mode)
        return;
    m_mode = next;
    emit changed();
}

void Theme::setFolderColor(const QString &color) {
    const QString next = color.isEmpty() ? QString("accent") : color;
    if (next == m_folderColor)
        return;
    m_folderColor = next;
    emit changed();
}

bool Theme::isDark() const {
    if (m_mode == "light")
        return false;
    if (m_mode == "dark")
        return true;
    return m_vexDark;
}

// The Vex colours when they match the mode in use, otherwise a neutral
// palette of the other brightness.
QColor Theme::background() const {
    if (isDark() == m_vexDark)
        return color("background", isDark() ? "#0e0e10" : "#f7f6f3");
    return isDark() ? QColor("#121214") : QColor("#f7f6f3");
}

QColor Theme::text() const {
    if (isDark() == m_vexDark)
        return color("foreground", isDark() ? "#ececf0" : "#1f1d1a");
    return isDark() ? QColor("#ececf0") : QColor("#1f1d1a");
}

QColor Theme::readable(const QColor &in) const {
    if (isDark() || !in.isValid())
        return in;
    QColor c = in;
    for (int i = 0; i < 6 && c.lightnessF() > 0.45; ++i)
        c = c.darker(118);
    return c;
}

void Theme::setLogoStyle(const QString &style) {
    const QString next = style == "sombre" || style == "clair" ? style : QString("plein");
    if (next == m_logoStyle)
        return;
    m_logoStyle = next;
    emit changed();
}

QVariantMap Theme::logoColors(const QString &app, const QString &styleIn) const {
    const auto style = styleIn.isEmpty() ? m_logoStyle : styleIn;
    const auto c = app == "flaircode" || app == "flairweb" ? LauncherIcons::codeColors(highlight(), style)
                                      : LauncherIcons::flairColors(highlight(), style);
    return {{"tile", c.tile}, {"back", c.back}, {"front", c.front}, {"spark", c.spark}};
}

QColor Theme::highlight() const {
    if (m_override.isValid())
        return m_override;
    const QColor accent(m_accent);
    if (accent.hslSaturationF() >= 0.3)
        return accent;
    return mostVivid(m_colors, accent);
}

QColor Theme::highlightText() const {
    const QColor c = highlight();
    auto linear = [](double v) { return v <= .04045 ? v / 12.92 : std::pow((v + .055) / 1.055, 2.4); };
    const double luminance = .2126 * linear(c.redF()) + .7152 * linear(c.greenF()) + .0722 * linear(c.blueF());
    return luminance > .179 ? QColor("#0b0b0d") : QColor("#ffffff");
}

QColor Theme::kindColor(const QString &kind) const {
    if (kind == "dossier") {
        if (m_folderColor == "neutral")
            return textDim();
        // Folders wear the theme colour as is, light or dark.
        const QColor custom(m_folderColor);
        return custom.isValid() ? custom : highlight();
    }
    if (kind == "image")
        return readable(color("bright_magenta", color("magenta", "#c792ea")));
    if (kind == "video")
        return readable(color("bright_red", color("red", "#f07178")));
    if (kind == "audio")
        return readable(color("bright_yellow", color("yellow", "#ffcb6b")));
    if (kind == "code")
        return readable(color("bright_cyan", color("cyan", "#89ddff")));
    if (kind == "document" || kind == "presentation" || kind == "tableur")
        return readable(color("bright_blue", color("blue", "#82aaff")));
    if (kind == "archive")
        return readable(color("orange", color("yellow", "#f78c6c")));
    if (kind == "installeur")
        return readable(color("bright_green", color("green", "#c3e88d")));
    return textDim();
}

QColor Theme::languageColor(const QString &language) const {
    static const QHash<QString, QString> keys{
        {"C++", "blue"},        {"C", "blue"},          {"Rust", "orange"},   {"Go", "cyan"},
        {"Python", "yellow"},   {"JavaScript", "yellow"}, {"TypeScript", "blue"}, {"Shell", "green"},
        {"QML", "green"},       {"Lua", "blue"},        {"HTML", "red"},      {"CSS", "magenta"},
        {"Dart", "cyan"},       {"Java", "orange"},     {"Kotlin", "magenta"}, {"Ruby", "red"},
        {"PHP", "magenta"},     {"Nix", "blue"},        {"Vue", "green"},     {"Svelte", "orange"}};
    const auto key = keys.value(language);
    return key.isEmpty() ? textFaint() : readable(color("bright_" + key, color(key, textDim())));
}

QColor Theme::syntax(const QString &role) const {
    if (role == "keyword")
        return readable(color("bright_magenta", color("magenta", "#c792ea")));
    if (role == "string")
        return readable(color("bright_green", color("green", "#c3e88d")));
    if (role == "number" || role == "constant")
        return readable(color("orange", color("bright_yellow", "#f78c6c")));
    if (role == "comment")
        return textFaint();
    if (role == "function")
        return readable(color("bright_blue", color("blue", "#82aaff")));
    if (role == "type")
        return readable(color("bright_cyan", color("cyan", "#89ddff")));
    if (role == "tag")
        return readable(color("bright_red", color("red", "#f07178")));
    if (role == "attribute")
        return readable(color("bright_yellow", color("yellow", "#ffcb6b")));
    if (role == "heading" || role == "preprocessor")
        return highlight();
    if (role == "operator")
        return textDim();
    return text();
}

QColor Theme::alpha(const QColor &c, double opacity) const {
    QColor out = c;
    out.setAlphaF(float(opacity));
    return out;
}

void Theme::reload() {
    const auto paths = m_watcher.files() + m_watcher.directories();
    if (!paths.isEmpty())
        m_watcher.removePaths(paths);

    // A theme switch replaces symlinks and files, so watch the parents too and
    // re-arm after every change. Watching the nearest existing ancestor means
    // installing Vex later works without restarting the app.
    QString ancestor = m_directory;
    while (!QFileInfo::exists(ancestor) && ancestor != "/")
        ancestor = QFileInfo(ancestor).absolutePath();
    QStringList candidates{ancestor, QFileInfo(ancestor).absolutePath(), m_directory,
                           m_directory + "/theme", m_directory + "/theme/colors.toml"};
    candidates.removeDuplicates();
    for (const auto &path : candidates)
        if (QFileInfo::exists(path))
            m_watcher.addPath(path);

    const auto colors = readColors(m_directory + "/theme/colors.toml");
    bool vexDark = true;
    {
        QFile file(m_directory + "/theme/colors.toml");
        if (file.open(QIODevice::ReadOnly)) {
            static const QRegularExpression modeLine(R"re(^\s*mode\s*=\s*["'](\w+)["'])re", QRegularExpression::MultilineOption);
            const auto match = modeLine.match(QString::fromUtf8(file.readAll()));
            if (match.hasMatch())
                vexDark = match.captured(1) != "light";
            else if (colors.contains("background"))
                vexDark = colors.value("background").lightnessF() < 0.5;
        }
    }
    if (vexDark != m_vexDark) {
        m_vexDark = vexDark;
        emit changed();
    }
    const QString accent = colors.contains("accent") ? colors.value("accent").name() : QString("#FFD60A");
    if (accent.compare(m_accent, Qt::CaseInsensitive) != 0 || colors != m_colors) {
        m_accent = accent;
        m_colors = colors;
        emit changed();
    }
}
