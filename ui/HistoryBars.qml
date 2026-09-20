import QtQuick
import qs.Commons

// Histogram used by the CPU and network cards. `sampleSeries` is the primary
// series and `stackSeries` stacks on top of it (system over user, or transmit
// over receive). Both are arrays of 0..1 fractions, oldest first. Built from
// plain items rather than a Canvas so it stays cheap and theme-coloured.
Item {
    id: root

    property var sampleSeries: []
    property var stackSeries: []
    property color primaryColor: Color.accent
    property color secondaryColor: Util.alpha(Color.foreground, 0.55)
    property color trackColor: Util.alpha(Color.foreground, 0.10)
    // When true the series are raw values scaled against the largest sample in
    // the window instead of 0..1 fractions. Used by the throughput graph.
    property bool autoScale: false
    property real scaleFloor: 0

    readonly property real scaleMax: {
        if (!autoScale) return 1
        var peak = 0
        for (var i = 0; i < sampleSeries.length; i++)
            peak = Math.max(peak, Number(sampleSeries[i]) || 0)
        for (var j = 0; j < stackSeries.length; j++)
            peak = Math.max(peak, Number(stackSeries[j]) || 0)
        return Math.max(peak / 0.9, scaleFloor > 0 ? scaleFloor : 1)
    }

    readonly property int count: Math.max(sampleSeries.length, stackSeries.length)
    readonly property real slot: count > 0 ? width / count : width
    readonly property real barWidth: Math.max(1, slot * 0.7)

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: 1
        border.color: root.trackColor
        visible: root.count < 2
    }

    Repeater {
        model: root.count

        delegate: Item {
            id: cell
            required property int index
            x: index * root.slot
            y: 0
            width: root.slot
            height: root.height

            Rectangle {
                id: lowBar
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                width: root.barWidth
                height: {
                    var fraction = Math.max(0, Math.min(1, (Number(root.sampleSeries[cell.index]) || 0) / root.scaleMax))
                    return fraction > 0 ? Math.max(1, fraction * (root.height - 2)) : 0
                }
                color: root.primaryColor
            }

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.barWidth
                height: {
                    var fraction = Math.max(0, Math.min(1, (Number(root.stackSeries[cell.index]) || 0) / root.scaleMax))
                    return fraction > 0 ? Math.max(1, fraction * (root.height - 2)) : 0
                }
                y: parent.height - lowBar.height - height
                color: root.secondaryColor
            }
        }
    }
}
