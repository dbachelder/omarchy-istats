import QtQuick
import qs.Commons

// Card shell for the panel: a rounded, subtly filled surface with a section
// title, an optional right-aligned value, and arbitrary content below.
Item {
    id: root

    property string title: ""
    property string valueText: ""
    property color accentColor: Color.accent
    property color ink: Color.foreground
    property int contentSpacing: Style.space(8)
    // Set on the card the user clicked for in the bar, so the panel makes it
    // obvious which domain they asked about.
    property bool highlighted: false
    default property alias content: body.children

    readonly property int padding: Style.space(11)
    readonly property int borderWidth: 1

    width: parent ? parent.width : 0
    implicitHeight: layout.implicitHeight + padding * 2 + borderWidth * 2

    Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Util.alpha(root.ink, root.highlighted ? 0.08 : 0.05)
        border.width: root.borderWidth
        border.color: root.highlighted ? Util.alpha(root.accentColor, 0.6) : Util.alpha(root.ink, 0.13)

        Behavior on border.color {
            ColorAnimation { duration: 180 }
        }
    }

    Column {
        id: layout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.padding + root.borderWidth
        spacing: root.contentSpacing

        Row {
            id: header
            width: parent.width
            height: Math.max(titleText.implicitHeight, valueLabel.implicitHeight)
            visible: root.title !== "" || root.valueText !== ""

            Text {
                id: titleText
                text: root.title
                visible: root.title !== ""
                color: root.accentColor
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                font.letterSpacing: 0.4
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
            }

            Item {
                width: Math.max(0, header.width - titleText.implicitWidth - valueLabel.implicitWidth)
                height: 1
            }

            Text {
                id: valueLabel
                text: root.valueText
                visible: root.valueText !== ""
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Column {
            id: body
            width: parent.width
            spacing: root.contentSpacing
        }
    }
}
