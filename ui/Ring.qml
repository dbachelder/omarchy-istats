import QtQuick
import QtQuick.Shapes
import qs.Commons

// Circular gauge. `value` is 0..1 and drives the arc sweep clockwise from the
// top. The centre carries an optional headline and caption, so one component
// covers both the big panel dials and the small per-thread rings.
Item {
    id: root

    property real value: 0
    property color fillColor: Color.accent
    property color trackColor: Util.alpha(Color.foreground, 0.16)
    property real thickness: Math.max(2, Math.round(width * 0.11))
    property string headline: ""
    property string caption: ""
    property int headlineSize: Style.font.body
    property int captionSize: Style.font.caption
    property color textColor: Color.foreground

    readonly property real fraction: Math.max(0, Math.min(1, value))
    readonly property real radius: Math.max(0, (Math.min(width, height) - thickness) / 2)
    readonly property real centreX: width / 2
    readonly property real centreY: height / 2

    Shape {
        anchors.fill: parent
        antialiasing: true

        ShapePath {
            strokeColor: root.trackColor
            strokeWidth: root.thickness
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.centreX
                centerY: root.centreY
                radiusX: root.radius
                radiusY: root.radius
                startAngle: -90
                sweepAngle: 359.99
            }
        }

        ShapePath {
            strokeColor: root.fillColor
            strokeWidth: root.thickness
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.centreX
                centerY: root.centreY
                radiusX: root.radius
                radiusY: root.radius
                startAngle: -90
                sweepAngle: Math.max(0.001, root.fraction * 360)

                Behavior on sweepAngle {
                    NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        visible: root.headline !== "" || root.caption !== ""
        spacing: 0

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.headline
            visible: root.headline !== ""
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: root.headlineSize
            font.bold: true
            textFormat: Text.PlainText
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.caption
            visible: root.caption !== ""
            color: Util.alpha(root.textColor, 0.7)
            font.family: Style.font.family
            font.pixelSize: root.captionSize
            textFormat: Text.PlainText
        }
    }
}
