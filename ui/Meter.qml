import QtQuick
import qs.Commons

// Horizontal capsule meter. Value is 0..1; the fill is clamped and animated so
// a 1 Hz sample stream reads as motion rather than as stepping.
Item {
    id: root

    property real value: 0
    property color fillColor: Color.accent
    property color trackColor: Util.alpha(Color.foreground, 0.16)

    implicitHeight: Math.max(4, Math.round(Style.font.caption * 0.6))
    implicitWidth: Style.space(48)
    readonly property real fraction: Math.max(0, Math.min(1, value))

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.trackColor
    }

    Rectangle {
        id: fill
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.max(root.height, root.fraction * parent.width)
        visible: root.fraction > 0.005
        radius: height / 2
        color: root.fillColor

        Behavior on color {
            ColorAnimation { duration: 220 }
        }
        Behavior on width {
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }
    }
}
