import QtQuick
import QtQuick.Shapes

// The Flair Web mark: a globe with flair's spark rising from it. Drawn in the
// suite accent; pkgbuild/flairweb.svg is the same drawing in orange.
Item {
    id: logo
    property real size: 28
    property string variant: ""
    readonly property var colors: (theme.highlight, theme.logoStyle, theme.logoColors("flairweb", variant))
    readonly property color tile: colors.tile
    readonly property color ink: colors.front
    readonly property color spark: colors.spark

    implicitWidth: size
    implicitHeight: size

    Rectangle {
        anchors.fill: parent
        radius: logo.size * 0.235
        color: logo.tile
    }

    Shape {
        width: 256
        height: 256
        scale: logo.size / 256
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: logo.ink
            strokeWidth: 22
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathSvg { path: "M48 140a72 72 0 1 0 144 0a72 72 0 1 0-144 0" }
        }
        ShapePath {
            strokeColor: logo.ink
            strokeWidth: 16
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathSvg { path: "M90 140a30 72 0 1 0 60 0a30 72 0 1 0-60 0M52 140h136" }
        }
        // A tile-coloured halo cuts the globe where the spark sits.
        ShapePath {
            strokeColor: logo.tile
            strokeWidth: 18
            joinStyle: ShapePath.RoundJoin
            fillColor: logo.tile
            PathSvg { path: "M188 30C191.4 60 202 70.6 232 74C202 77.4 191.4 88 188 118C184.6 88 174 77.4 144 74C174 70.6 184.6 60 188 30z" }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: logo.spark
            PathSvg { path: "M188 30C191.4 60 202 70.6 232 74C202 77.4 191.4 88 188 118C184.6 88 174 77.4 144 74C174 70.6 184.6 60 188 30z" }
        }
    }
}
