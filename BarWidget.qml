import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ui"

// iStats — an iStat Menus-shaped bar entry.
//
// The bar row carries the five readings a Mac menubar usually shows (network
// throughput, CPU, GPU, memory, storage) instead of collapsing them into one
// icon. Each reading is its own hit target: clicking MEM opens the dashboard
// ordered for memory (its history, then the processes actually holding RAM),
// clicking CPU orders it for the processor, and so on. All numbers come from one
// stdlib Python collector that streams a JSON frame per second on stdout, so
// nothing here polls the filesystem itself.
BarWidget {
    id: root

    moduleName: "io.github.dbachelder.istats"

    // ---------------------------------------------------------------- data
    property var sample: ({})
    property var cpuHistory: []
    property var netDownHistory: []
    property var netUpHistory: []
    property var gpuHistory: []
    property var memHistory: []
    property var diskReadHistory: []
    property var diskWriteHistory: []
    property int historyLength: 60
    property bool popupOpen: false
    // Which reading the bar was clicked for. Drives the order and emphasis of
    // the dashboard. "overview" is the neutral order.
    property string focusSection: "overview"
    // Last reading the pointer reported, so the row tooltip is only rebuilt
    // when the pointer crosses into a different cell.
    property string hoverTip: ""

    readonly property int intervalSec: Math.max(1, Number(root.setting("intervalSec", 1)) || 1)
    readonly property bool colorful: root.settingBool("colorful", true)

    // The PopupCard's outside-click path calls owner.close() when it exists;
    // without these, dismissal would write PopupCard.open directly and break
    // the open: binding that drives it from popupOpen.
    function close() { root.popupOpen = false }
    function open() { root.focusSection = "overview"; root.popupOpen = true }
    function openFor(section) { root.focusSection = section; root.popupOpen = true }
    function toggle() { root.popupOpen = !root.popupOpen }

    // Clicking the same reading twice closes again, so a reading behaves like
    // the popup it owns rather than like a one-way door.
    function focusAndOpen(section) {
        if (root.popupOpen && root.focusSection === section) {
            root.popupOpen = false
            return
        }
        root.focusSection = section
        root.popupOpen = true
    }

    function settingBool(name, fallback) {
        var value = root.setting(name, fallback)
        if (value === true || value === false) return value
        var text = String(value).toLowerCase()
        if (text === "false" || text === "0" || text === "no" || text === "off") return false
        if (text === "true" || text === "1" || text === "yes" || text === "on") return true
        return fallback
    }

    readonly property string scriptPath: String(Qt.resolvedUrl("collector/istats_collector.py")).replace(/^file:\/\//, "")

    // ------------------------------------------------------------- palette
    // colors.toml is re-read so a theme switch repaints the gauges without a
    // shell restart. Defaults are the theme-agnostic iStats hues.
    property var palette: ({
        cyan: "#2DD5B7",
        magenta: "#D2689C",
        blue: "#509475",
        yellow: "#E5C736",
        green: "#549e6a",
        red: "#FF5345"
    })

    function loadPalette(raw) {
        var next = {
            cyan: "#2DD5B7",
            magenta: "#D2689C",
            blue: "#509475",
            yellow: "#E5C736",
            green: "#549e6a",
            red: "#FF5345"
        }
        var lines = String(raw || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["'](#[0-9A-Fa-f]{6})/)
            if (!match) continue
            if (next[match[1]] !== undefined || ["cyan", "magenta", "blue", "yellow", "green", "red"].indexOf(match[1]) >= 0)
                next[match[1]] = match[2]
        }
        root.palette = next
    }

    FileView {
        path: Color.currentThemePath + "/colors.toml"
        watchChanges: true
        printErrors: false
        onLoaded: root.loadPalette(text())
        onFileChanged: reload()
    }

    readonly property color barInk: bar ? bar.barForeground : Color.foreground
    readonly property color panelInk: Color.popups.text
    readonly property color cpuColor: root.colorful ? root.palette.cyan : Color.accent
    readonly property color gpuColor: root.colorful ? root.palette.magenta : Color.accent
    readonly property color memColor: root.colorful ? root.palette.blue : Color.accent
    readonly property color ssdColor: root.colorful ? root.palette.yellow : Color.accent
    readonly property color userColor: root.colorful ? root.palette.magenta : Color.accent
    readonly property color systemColor: root.colorful ? root.palette.blue : Util.alpha(Color.foreground, 0.6)

    // ------------------------------------------------------------ readings
    readonly property var cpu: sample.cpu || ({})
    readonly property var mem: sample.mem || ({})
    readonly property var disk: (sample.disk && sample.disk.root) ? sample.disk.root : ({})
    readonly property var diskIo: sample.disk || ({})
    readonly property var net: sample.net || ({})
    readonly property var gpu: (sample.gpus && sample.gpus.length > 0) ? sample.gpus[0] : ({})
    readonly property var procs: sample.procs || []
    readonly property var procsMem: sample.procs_mem || []
    readonly property var loads: sample.load || [0, 0, 0]
    readonly property var cores: cpu.cores || []
    readonly property int coreCount: sample.cores || 0
    readonly property bool hasData: sample.t !== undefined

    // The hogs table follows the click: memory focus lists RSS leaders, every
    // other focus lists CPU leaders.
    readonly property bool memFocus: root.focusSection === "mem"
    readonly property var hogList: root.memFocus ? root.procsMem : root.procs
    readonly property string hogTitle: root.memFocus ? "MEMORY HOGS" : (root.focusSection === "cpu" ? "CPU HOGS" : "PROCESSES")
    readonly property color hogColor: root.memFocus ? root.memColor : root.cpuColor

    readonly property bool showNet: root.settingBool("showNet", true)
    readonly property bool showCpu: root.settingBool("showCpu", true)
    readonly property bool showGpu: root.settingBool("showGpu", true)
    readonly property bool showMem: root.settingBool("showMem", true)
    readonly property bool showSsd: root.settingBool("showSsd", true)
    readonly property int processCount: Math.max(3, Math.min(12, Number(root.setting("processCount", 6)) || 6))

    // --------------------------------------------------------- collector
    Process {
        id: collector
        running: true
        command: ["python3", root.scriptPath, "--interval", String(root.intervalSec)]
        stdout: SplitParser {
            onRead: function(line) {
                root.ingest(line)
            }
        }
    }

    Timer {
        id: respawn
        interval: 3000
        repeat: false
        onTriggered: collector.running = true
    }

    onIntervalSecChanged: {
        collector.running = false
        respawn.restart()
    }

    function ingest(line) {
        var frame
        try {
            frame = JSON.parse(line)
        } catch (error) {
            return
        }
        if (!frame || frame.t === undefined) return
        root.sample = frame
        root.cpuHistory = push(root.cpuHistory, (Number(frame.cpu && frame.cpu.user) || 0) / 100)
        root.netDownHistory = push(root.netDownHistory, Number(frame.net && frame.net.down_bps) || 0)
        root.netUpHistory = push(root.netUpHistory, Number(frame.net && frame.net.up_bps) || 0)
        root.gpuHistory = push(root.gpuHistory, (Number(frame.gpus && frame.gpus[0] && frame.gpus[0].util) || 0) / 100)
        root.memHistory = push(root.memHistory, (Number(frame.mem && frame.mem.pct) || 0) / 100)
        root.diskReadHistory = push(root.diskReadHistory, Number(frame.disk && frame.disk.read_bps) || 0)
        root.diskWriteHistory = push(root.diskWriteHistory, Number(frame.disk && frame.disk.write_bps) || 0)
    }

    function push(list, value) {
        var next = list.slice(Math.max(0, list.length - (root.historyLength - 1)))
        next.push(value)
        return next
    }

    // ---------------------------------------------------------- formatting
    function fmtRate(bps) {
        var value = Number(bps)
        if (!isFinite(value) || value <= 0) return "0 B/s"
        var units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var index = 0
        while (value >= 1024 && index < units.length - 1) {
            value /= 1024
            index++
        }
        return (value >= 100 ? Math.round(value) : value.toFixed(1)) + " " + units[index]
    }

    function fmtBytes(bytes) {
        var value = Number(bytes)
        if (!isFinite(value) || value <= 0) return "0"
        var units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var index = 0
        while (value >= 1024 && index < units.length - 1) {
            value /= 1024
            index++
        }
        return (value >= 100 ? Math.round(value) : value.toFixed(1)) + " " + units[index]
    }

    function fmtUptime(seconds) {
        var total = Math.max(0, Math.floor(Number(seconds) || 0))
        var days = Math.floor(total / 86400)
        var hours = Math.floor((total % 86400) / 3600)
        var minutes = Math.floor((total % 3600) / 60)
        if (days > 0) return days + (days === 1 ? " day" : " days") + ", " + hours + (hours === 1 ? " hour" : " hours")
        if (hours > 0) return hours + (hours === 1 ? " hour" : " hours") + ", " + minutes + " min"
        return minutes + (minutes === 1 ? " minute" : " minutes")
    }

    function pct(value, decimals) {
        var number = Number(value)
        if (!isFinite(number)) return "--"
        return number.toFixed(decimals === undefined ? 0 : decimals) + "%"
    }

    function heatColor(value, base) {
        var fraction = Math.max(0, Math.min(1, Number(value) || 0))
        if (fraction >= 0.85) return root.colorful ? root.palette.red : Color.urgent
        if (fraction >= 0.6) return root.colorful ? root.palette.yellow : Color.accent
        return base === undefined ? root.cpuColor : base
    }

    function glyphColor(name) {
        var options = [root.palette.cyan, root.palette.magenta, root.palette.blue, root.palette.yellow, root.palette.green]
        var hash = 0
        var text = String(name || "?")
        for (var i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) >>> 0
        return options[hash % options.length]
    }

    // ------------------------------------------------------- panel order
    // The clicked domain leads, its hogs table follows it, and everything else
    // keeps the neutral order behind them.
    function orderFor(section) {
        var all = ["cpu", "hogs", "gpu", "mem", "disk", "net", "load", "uptime"]
        var leading = []
        if (section === "cpu") leading = ["cpu", "hogs"]
        else if (section === "mem") leading = ["mem", "hogs"]
        else if (section === "gpu") leading = ["gpu", "hogs"]
        else if (section === "disk") leading = ["disk", "hogs"]
        else if (section === "net") leading = ["net", "hogs"]
        var rest = []
        for (var i = 0; i < all.length; i++)
            if (leading.indexOf(all[i]) < 0) rest.push(all[i])
        return leading.concat(rest)
    }

    readonly property var sectionOrder: root.orderFor(root.focusSection)

    function componentFor(key) {
        if (key === "cpu") return cpuCard
        if (key === "hogs") return hogsCard
        if (key === "gpu") return gpuCard
        if (key === "mem") return memCard
        if (key === "disk") return diskCard
        if (key === "net") return netCard
        if (key === "load") return loadCard
        if (key === "uptime") return uptimeCard
        return null
    }

    // ----------------------------------------------------------- tooltips
    function tooltipFor(section) {
        if (section === "net") {
            return [
                "Network · " + (root.net.iface || "—"),
                "↓ " + root.fmtRate(root.net.down_bps) + "    ↑ " + root.fmtRate(root.net.up_bps),
                "Click for network detail"
            ].join("\n")
        }
        if (section === "cpu") {
            return [
                "CPU · " + root.pct(root.cpu.total),
                (root.cpu.freq_ghz ? root.cpu.freq_ghz + " GHz" : "—")
                    + (root.cpu.temp ? " · " + root.cpu.temp + "°" : ""),
                "Click for CPU detail"
            ].join("\n")
        }
        if (section === "gpu") {
            return [
                "GPU · " + root.pct(root.gpu.util),
                root.gpu.name || "—",
                "Click for GPU detail"
            ].join("\n")
        }
        if (section === "mem") {
            return [
                "Memory · " + root.pct(root.mem.pct),
                root.fmtBytes(root.mem.used) + " / " + root.fmtBytes(root.mem.total),
                "Click for memory detail and top users"
            ].join("\n")
        }
        if (section === "disk") {
            return [
                "Disk · " + root.pct(root.disk.pct),
                root.fmtBytes(root.disk.free) + " free on " + (root.disk.mount || "/"),
                "Click for disk detail"
            ].join("\n")
        }
        return ""
    }

    // Which reading sits under a point in the bar row. The row is laid out by a
    // Row positioner, so a cell's x is its offset inside the row and lines up
    // with the hit-test area's local coordinates.
    function sectionAtX(px) {
        var cells = [
            { item: networkCell, key: "net" },
            { item: cpuCell, key: "cpu" },
            { item: gpuCell, key: "gpu" },
            { item: memCell, key: "mem" },
            { item: ssdCell, key: "disk" }
        ]
        for (var i = 0; i < cells.length; i++) {
            var cell = cells[i].item
            if (!cell || !cell.visible) continue
            if (px >= cell.x && px <= cell.x + cell.width) return cells[i].key
        }
        return "overview"
    }

    function summaryTooltip() {
        var lines = ["iStats"]
        lines.push("CPU " + root.pct(root.cpu.total) + " · " + (root.cpu.freq_ghz ? root.cpu.freq_ghz + " GHz" : "—")
            + (root.cpu.temp ? " · " + root.cpu.temp + "°" : ""))
        lines.push("GPU " + root.pct(root.gpu.util) + (root.gpu.name ? " · " + root.gpu.name : ""))
        lines.push("Memory " + root.pct(root.mem.pct) + " · " + root.fmtBytes(root.mem.used) + " / " + root.fmtBytes(root.mem.total))
        lines.push("Disk " + root.pct(root.disk.pct) + " · " + root.fmtBytes(root.disk.free) + " free")
        lines.push("Net ↓ " + root.fmtRate(root.net.down_bps) + " ↑ " + root.fmtRate(root.net.up_bps)
            + (root.net.iface ? "  (" + root.net.iface + ")" : ""))
        lines.push("Click a reading for its detail")
        return lines.join("\n")
    }

    function updateRowTooltip(px) {
        var section = root.sectionAtX(px)
        if (section === root.hoverTip) return
        root.hoverTip = section
        if (!root.bar) return
        root.bar.showTooltip(root, section === "overview" ? root.summaryTooltip() : root.tooltipFor(section))
    }

    // ------------------------------------------------------------ ipc
    // Lets `omarchy-shell` / keybinds open the dashboard without a click.
    IpcHandler {
        target: "io.github.dbachelder.istats"

        function open(): void { root.open() }
        function close(): void { root.popupOpen = false }
        function toggle(): void { root.toggle() }
        // One no-argument entry point per reading: the ipc CLI here does not
        // forward string arguments, and these read better in a keybind anyway.
        function overview(): void { root.openFor("overview") }
        function showCpu(): void { root.openFor("cpu") }
        function showGpu(): void { root.openFor("gpu") }
        function showMem(): void { root.openFor("mem") }
        function showDisk(): void { root.openFor("disk") }
        function showNet(): void { root.openFor("net") }
        function status(): string {
            return JSON.stringify({
                focus: root.focusSection,
                cpu: root.cpu.total,
                gpu: root.gpu.util,
                mem: root.mem.pct,
                disk: root.disk.pct,
                down: root.net.down_bps,
                up: root.net.up_bps
            })
        }
    }

    // --------------------------------------------------------- bar entry
    implicitWidth: barRow.implicitWidth + Style.space(14)
    implicitHeight: barSize

    // Handles only the padding around the row; the row itself owns its own
    // hit-test area below.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.focusAndOpen("overview")
        onEntered: {
            root.hoverTip = "overview"
            if (root.bar) root.bar.showTooltip(root, root.summaryTooltip())
        }
        onExited: {
            root.hoverTip = ""
            if (root.bar) root.bar.hideTooltip(root)
        }
    }

    Row {
        id: barRow
        anchors.centerIn: parent
        spacing: Style.space(11)

        // Network: the two-line up/down pair, exactly as the menubar shows it.
        // The column width is fixed and each rate is right-aligned against its
        // own arrow, so a reading going from "9.9 KB/s" to "10.1 MB/s" cannot
        // change the entry's width and shove the rest of the bar sideways.
        Column {
            id: networkCell
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showNet && !root.vertical
            spacing: 0
            width: Style.space(74)

            Row {
                spacing: Style.space(4)
                width: parent.width

                Text {
                    id: upArrow
                    text: "↑"
                    color: root.barInk
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.fmtRate(root.net.up_bps)
                    width: Math.max(0, parent.width - upArrow.implicitWidth - parent.spacing)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                    color: root.barInk
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Row {
                spacing: Style.space(4)
                width: parent.width

                Text {
                    id: downArrow
                    text: "↓"
                    color: Util.alpha(root.barInk, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.fmtRate(root.net.down_bps)
                    width: Math.max(0, parent.width - downArrow.implicitWidth - parent.spacing)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                    color: Util.alpha(root.barInk, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

        }

        // CPU / GPU / MEM / SSD capsules.
        Column {
            id: cpuCell
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showCpu
            spacing: Style.space(2)
            width: Style.space(50)

            Row {
                spacing: Style.space(4)
                Text {
                    text: "CPU"
                    color: Util.alpha(root.barInk, 0.7)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
                Text {
                    text: root.pct(root.cpu.total)
                    color: root.barInk
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    textFormat: Text.PlainText
                }
            }
            Meter {
                width: parent.width
                value: (Number(root.cpu.total) || 0) / 100
                fillColor: root.heatColor((Number(root.cpu.total) || 0) / 100)
            }

        }

        Column {
            id: gpuCell
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showGpu
            spacing: Style.space(2)
            width: Style.space(50)

            Row {
                spacing: Style.space(4)
                Text {
                    text: "GPU"
                    color: Util.alpha(root.barInk, 0.7)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
                Text {
                    text: root.pct(root.gpu.util)
                    color: root.barInk
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    textFormat: Text.PlainText
                }
            }
            Meter {
                width: parent.width
                value: (Number(root.gpu.util) || 0) / 100
                fillColor: root.gpuColor
            }

        }

        Column {
            id: memCell
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showMem
            spacing: Style.space(2)
            width: Style.space(50)

            Row {
                spacing: Style.space(4)
                Text {
                    text: "MEM"
                    color: Util.alpha(root.barInk, 0.7)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
                Text {
                    text: root.pct(root.mem.pct)
                    color: root.barInk
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    textFormat: Text.PlainText
                }
            }
            Meter {
                width: parent.width
                value: (Number(root.mem.pct) || 0) / 100
                fillColor: root.memColor
            }

        }

        Column {
            id: ssdCell
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showSsd
            spacing: Style.space(2)
            width: Style.space(50)

            Row {
                spacing: Style.space(4)
                Text {
                    text: "SSD"
                    color: Util.alpha(root.barInk, 0.7)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
                Text {
                    text: root.pct(root.disk.pct)
                    color: root.barInk
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    textFormat: Text.PlainText
                }
            }
            Meter {
                width: parent.width
                value: (Number(root.disk.pct) || 0) / 100
                fillColor: root.ssdColor
            }

        }
    }

    // One hit-test area over the whole row rather than a MouseArea per cell:
    // the cells live in a Row positioner (where anchors are disallowed), and a
    // single area that maps the pointer to a reading keeps the click and the
    // tooltip in agreement. Declared after the row, so it wins over the padding
    // area above.
    MouseArea {
        anchors.centerIn: parent
        width: barRow.implicitWidth
        height: barRow.implicitHeight
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) { root.focusAndOpen(root.sectionAtX(mouse.x)) }
        onEntered: root.updateRowTooltip(mouse.x)
        onPositionChanged: function(mouse) { root.updateRowTooltip(mouse.x) }
        onExited: {
            root.hoverTip = ""
            if (root.bar) root.bar.hideTooltip(root)
        }
    }

    // ---------------------------------------------------------- dropdown
    PopupCard {
        id: popup
        anchorItem: root
        bar: root.bar
        owner: root
        open: root.popupOpen
        contentWidth: popup.fittedContentWidth(Style.space(440))
        contentHeight: popup.fittedContentHeight(scroll.implicitHeight)

        Flickable {
            id: scroll
            anchors.fill: parent
            implicitHeight: column.implicitHeight
            contentWidth: width
            contentHeight: column.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: column
                width: scroll.width
                spacing: Style.space(9)

                // The clicked domain's card comes first, so the panel answers
                // the exact reading the user pointed at.
                Repeater {
                    model: root.sectionOrder

                    delegate: Loader {
                        id: cardLoader
                        required property string modelData
                        width: column.width
                        sourceComponent: root.componentFor(modelData)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------- card bodies
    // Kept as non-visual Components so the Repeater above can order them by
    // the current focus without any one card owning a fixed position.

    Component {
        id: cpuCard
        Card {
            title: "CPU"
            accentColor: root.cpuColor
            ink: root.panelInk
            highlighted: root.focusSection === "cpu"
            valueText: (root.cpu.freq_ghz ? root.cpu.freq_ghz + " GHz" : "—")
                + (root.cpu.temp ? ", " + root.cpu.temp + "°" : "")

            HistoryBars {
                width: parent.width
                height: Style.space(54)
                sampleSeries: root.cpuHistory
                primaryColor: root.userColor
            }

            Row {
                width: parent.width

                Row {
                    id: userGroup
                    spacing: Style.space(6)

                    Rectangle {
                        width: Style.space(8)
                        height: width
                        radius: width / 2
                        color: root.userColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "User"
                        color: root.panelInk
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.pct(root.cpu.user)
                        color: root.panelInk
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Item {
                    width: Math.max(0, parent.width - userGroup.width - systemGroup.width)
                    height: 1
                }

                Row {
                    id: systemGroup
                    spacing: Style.space(6)

                    Rectangle {
                        width: Style.space(8)
                        height: width
                        radius: width / 2
                        color: root.systemColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "System"
                        color: root.panelInk
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.pct(root.cpu.system)
                        color: root.panelInk
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            Item {
                width: parent.width
                height: coreFlow.implicitHeight

                Flow {
                    id: coreFlow
                    width: parent.width
                    spacing: Style.space(3)

                    Repeater {
                        model: root.cores

                        Ring {
                            required property var modelData
                            required property int index
                            width: Style.space(38)
                            height: width
                            value: (Number(modelData) || 0) / 100
                            fillColor: root.heatColor((Number(modelData) || 0) / 100)
                        }
                    }
                }
            }

            Row {
                width: parent.width

                Text {
                    id: threadLabel
                    text: "Threads"
                    color: Util.alpha(root.panelInk, 0.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }

                Item {
                    width: Math.max(0, parent.width - threadLabel.implicitWidth - threadValue.implicitWidth)
                    height: 1
                }

                Text {
                    id: threadValue
                    text: root.cores.length > 0 ? root.cores.length + " logical" : ""
                    color: Util.alpha(root.panelInk, 0.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
            }
        }
    }

    Component {
        id: hogsCard
        Card {
            title: root.hogTitle
            accentColor: root.hogColor
            ink: root.panelInk
            highlighted: root.focusSection === "cpu" || root.memFocus

            Column {
                width: parent.width
                spacing: Style.space(5)

                Repeater {
                    model: root.hogList.slice(0, root.processCount)

                    Row {
                        required property var modelData
                        width: parent.width
                        spacing: Style.space(8)

                        Rectangle {
                            width: Style.space(15)
                            height: width
                            radius: Style.space(3)
                            color: Util.alpha(root.glyphColor(modelData.name), 0.85)
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                anchors.centerIn: parent
                                text: String(modelData.name || "?").charAt(0).toUpperCase()
                                color: Color.background
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                font.bold: true
                                textFormat: Text.PlainText
                            }
                        }

                        Text {
                            text: modelData.name
                            width: Math.max(0, parent.width - Style.space(15) - Style.space(46) - memText.implicitWidth - Style.space(8) * 4)
                            elide: Text.ElideRight
                            color: root.panelInk
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            id: memText
                            text: root.fmtBytes(modelData.mem)
                            color: root.memFocus ? root.panelInk : Util.alpha(root.panelInk, 0.55)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            font.bold: root.memFocus
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: root.pct(modelData.cpu, 1)
                            color: root.memFocus ? Util.alpha(root.panelInk, 0.55) : root.panelInk
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: !root.memFocus
                            textFormat: Text.PlainText
                            horizontalAlignment: Text.AlignRight
                            width: Style.space(46)
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }
        }
    }

    Component {
        id: gpuCard
        Card {
            title: "GPU"
            accentColor: root.gpuColor
            ink: root.panelInk
            highlighted: root.focusSection === "gpu"
            valueText: root.gpu.name || "No GPU"

            Row {
                width: parent.width
                spacing: Style.space(6)

                Ring {
                    width: (parent.width - Style.space(18)) / 4
                    height: width
                    value: (Number(root.gpu.util) || 0) / 100
                    fillColor: root.gpuColor
                    textColor: root.panelInk
                    headline: root.pct(root.gpu.util)
                    caption: "GPU"
                    headlineSize: Style.font.title
                }
                Ring {
                    width: (parent.width - Style.space(18)) / 4
                    height: width
                    value: (Number(root.gpu.mem_used) || 0) / Math.max(1, Number(root.gpu.mem_total) || 1)
                    fillColor: root.gpuColor
                    textColor: root.panelInk
                    headline: root.pct((Number(root.gpu.mem_used) || 0) / Math.max(1, Number(root.gpu.mem_total) || 1) * 100)
                    caption: "MEM"
                    headlineSize: Style.font.title
                }
                Ring {
                    width: (parent.width - Style.space(18)) / 4
                    height: width
                    value: Math.min(1, (Number(root.gpu.temp) || 0) / 100)
                    fillColor: root.heatColor((Number(root.gpu.temp) || 0) / 100, root.gpuColor)
                    textColor: root.panelInk
                    headline: root.gpu.temp !== undefined && root.gpu.temp !== null ? Math.round(root.gpu.temp) + "°" : "--"
                    caption: "TMP"
                    headlineSize: Style.font.title
                }
                Ring {
                    width: (parent.width - Style.space(18)) / 4
                    height: width
                    value: Math.min(1, (Number(root.gpu.clock_mhz) || 0) / 3000)
                    fillColor: root.gpuColor
                    textColor: root.panelInk
                    headline: ((Number(root.gpu.clock_mhz) || 0) / 1000).toFixed(2)
                    caption: "GHZ"
                    headlineSize: Style.font.title
                }
            }

            Row {
                width: parent.width
                Text {
                    id: vramText
                    text: root.fmtBytes(root.gpu.mem_used) + " / " + root.fmtBytes(root.gpu.mem_total)
                    color: Util.alpha(root.panelInk, 0.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
                Item {
                    width: Math.max(0, parent.width - vramText.implicitWidth - powerText.implicitWidth)
                    height: 1
                }
                Text {
                    id: powerText
                    text: root.gpu.power !== undefined && root.gpu.power !== null ? Math.round(root.gpu.power) + " W" : ""
                    color: Util.alpha(root.panelInk, 0.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                }
            }
        }
    }

    Component {
        id: memCard
        Card {
            title: "MEMORY"
            accentColor: root.memColor
            ink: root.panelInk
            highlighted: root.memFocus
            valueText: root.pct(root.mem.pct)

            HistoryBars {
                width: parent.width
                height: Style.space(44)
                sampleSeries: root.memHistory
                primaryColor: root.memColor
            }

            Row {
                width: parent.width
                spacing: Style.space(14)

                Ring {
                    width: Style.space(84)
                    height: width
                    value: (Number(root.mem.pct) || 0) / 100
                    fillColor: root.memColor
                    textColor: root.panelInk
                    headline: root.fmtBytes(root.mem.used)
                    caption: "USED"
                    headlineSize: Style.font.subtitle
                }

                Column {
                    width: parent.width - Style.space(98)
                    spacing: Style.space(3)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: "Total   " + root.fmtBytes(root.mem.total)
                        color: root.panelInk
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        textFormat: Text.PlainText
                    }
                    Text {
                        text: "Free    " + root.fmtBytes(root.mem.available)
                        color: Util.alpha(root.panelInk, 0.7)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        textFormat: Text.PlainText
                    }
                    Text {
                        text: "Swap    " + root.fmtBytes(root.mem.swap_used) + " / " + root.fmtBytes(root.mem.swap_total)
                        color: Util.alpha(root.panelInk, 0.7)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        textFormat: Text.PlainText
                    }
                }
            }
        }
    }

    Component {
        id: diskCard
        Card {
            title: "DISK"
            accentColor: root.ssdColor
            ink: root.panelInk
            highlighted: root.focusSection === "disk"
            valueText: (root.disk.mount || "/") + "   " + root.pct(root.disk.pct)

            Row {
                width: parent.width
                spacing: Style.space(14)

                Ring {
                    width: Style.space(84)
                    height: width
                    value: (Number(root.disk.pct) || 0) / 100
                    fillColor: root.ssdColor
                    textColor: root.panelInk
                    headline: root.pct(root.disk.pct)
                    caption: "USED"
                    headlineSize: Style.font.subtitle
                }

                Column {
                    width: parent.width - Style.space(98)
                    spacing: Style.space(3)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: "Total   " + root.fmtBytes(root.disk.total)
                        color: root.panelInk
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        textFormat: Text.PlainText
                    }
                    Text {
                        text: "Used    " + root.fmtBytes(root.disk.used)
                        color: Util.alpha(root.panelInk, 0.7)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        textFormat: Text.PlainText
                    }
                    Text {
                        text: "Free    " + root.fmtBytes(root.disk.free)
                        color: Util.alpha(root.panelInk, 0.7)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        textFormat: Text.PlainText
                    }
                }
            }

            Row {
                width: parent.width
                spacing: Style.space(10)

                Column {
                    width: (parent.width - Style.space(10)) / 2
                    spacing: Style.space(3)

                    Text {
                        text: "READ   " + root.fmtRate(root.diskIo.read_bps)
                        color: root.palette.blue
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                    }
                    HistoryBars {
                        width: parent.width
                        height: Style.space(30)
                        sampleSeries: root.diskReadHistory
                        primaryColor: root.palette.blue
                        autoScale: true
                        scaleFloor: 8 * 1024 * 1024
                    }
                }

                Column {
                    width: (parent.width - Style.space(10)) / 2
                    spacing: Style.space(3)

                    Text {
                        text: "WRITE   " + root.fmtRate(root.diskIo.write_bps)
                        color: root.palette.yellow
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                    }
                    HistoryBars {
                        width: parent.width
                        height: Style.space(30)
                        sampleSeries: root.diskWriteHistory
                        primaryColor: root.palette.yellow
                        autoScale: true
                        scaleFloor: 8 * 1024 * 1024
                    }
                }
            }
        }
    }

    Component {
        id: netCard
        Card {
            title: "NETWORK"
            accentColor: root.memColor
            ink: root.panelInk
            highlighted: root.focusSection === "net"
            valueText: root.net.iface || "—"

            // Receive and transmit differ by orders of magnitude, so each gets
            // its own scale rather than sharing one axis.
            Row {
                width: parent.width
                spacing: Style.space(10)

                Column {
                    width: (parent.width - Style.space(10)) / 2
                    spacing: Style.space(3)

                    Text {
                        text: "DOWN   " + root.fmtRate(root.net.down_bps)
                        color: root.palette.blue
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                    }
                    HistoryBars {
                        width: parent.width
                        height: Style.space(34)
                        sampleSeries: root.netDownHistory
                        primaryColor: root.palette.blue
                        autoScale: true
                        scaleFloor: 256 * 1024
                    }
                }

                Column {
                    width: (parent.width - Style.space(10)) / 2
                    spacing: Style.space(3)

                    Text {
                        text: "UP   " + root.fmtRate(root.net.up_bps)
                        color: root.palette.cyan
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                    }
                    HistoryBars {
                        width: parent.width
                        height: Style.space(34)
                        sampleSeries: root.netUpHistory
                        primaryColor: root.palette.cyan
                        autoScale: true
                        scaleFloor: 1024 * 1024
                    }
                }
            }

            Text {
                text: "Received " + root.fmtBytes(root.net.rx_total) + "  ·  Sent " + root.fmtBytes(root.net.tx_total)
                color: Util.alpha(root.panelInk, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
            }
        }
    }

    Component {
        id: loadCard
        Card {
            title: "LOAD"
            accentColor: root.memColor
            ink: root.panelInk
            valueText: (Number(root.loads[0]) || 0).toFixed(2) + "  "
                + (Number(root.loads[1]) || 0).toFixed(2) + "  "
                + (Number(root.loads[2]) || 0).toFixed(2)
        }
    }

    Component {
        id: uptimeCard
        Card {
            title: "UPTIME"
            accentColor: root.memColor
            ink: root.panelInk
            valueText: root.fmtUptime(root.sample.uptime)
        }
    }
}
