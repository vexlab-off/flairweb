#pragma once

#include <QColor>
#include <QString>

// The suite's logos in every accent colour and style ("plein", "sombre",
// "clair"), and the per-user launcher entries that show them: when the accent
// changes, the icon in Super+Space changes with it.
namespace LauncherIcons {

struct Colors {
    QColor tile, back, front, spark;
};

Colors flairColors(const QColor &accent, const QString &style);
Colors codeColors(const QColor &accent, const QString &style);
QString flairSvg(const QColor &accent, const QString &style);
QString flaircodeSvg(const QColor &accent, const QString &style);
QString flairwebSvg(const QColor &accent, const QString &style);
QString imageSvg(const QColor &accent, const QString &style);
QString videoSvg(const QColor &accent, const QString &style);
// The SVG for an app id: flair, flaircode, flairweb, flair-image, flair-video.
QString svgFor(const QString &app, const QColor &accent, const QString &style);

// Writes the icons and ~/.local/share/applications overrides for each app
// that is installed, or removes the overrides when `follow` is false.
// `home` is the user's home directory (a temp dir in tests).
void apply(const QColor &accent, const QString &style, bool follow, const QString &home,
           const QString &systemApplications = "/usr/share/applications");

}
