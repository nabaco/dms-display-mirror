import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property bool autoRefresh: pluginData.autoRefresh ?? false
    property int refreshInterval: pluginData.refreshInterval || 30
    property string scalingMode: pluginData.scalingMode || "fit"
    property string scalingFilter: pluginData.scalingFilter || "linear"

    readonly property var scalingModeValues: ["fit", "cover", "exact"]
    readonly property var scalingModeLabels: ["Fit", "Cover", "Exact"]
    readonly property var scalingFilterValues: ["linear", "nearest"]
    readonly property var scalingFilterLabels: ["Linear", "Nearest"]

    // Reactive list of all connected outputs. Updates automatically on hotplug, so no manual refresh is required.
    property var monitors: Quickshell.screens.map(s => s.name)
    property bool wlMirrorInstalled: true
    property bool slurpInstalled: true

    // Use shared singleton state so all widget instances see the same values, and
    // so scaling changes made from one surface (bar/CC) reach the process
    // regardless of which surface originally started the mirror.
    // activeMirrors structure: {id: {source, target, scalingMode, scalingFilter, region, zoom, pid}}
    readonly property var activeMirrors: MirrorState.activeMirrors
    readonly property bool hasActiveMirrors: MirrorState.hasActiveMirrors
    readonly property int activeMirrorCount: MirrorState.activeMirrorCount
    property string lastMirrorError: ""
    property string currentFocusedOutput: ""
    // Incremented whenever mirror state changes to force dependent bindings to reevaluate
    property int mirrorVersion: 0

    // Explicit source/target selection, so a mirror can be started from any
    // screen (e.g. mirror the laptop onto a beamer without going to the beamer).
    // Empty string = "use the default" (see sourceChoice/targetChoice).
    property string selectedSource: ""
    property string selectedTarget: ""

    // Displays currently covered by a running mirror window - they can neither
    // be mirrored (you'd just see the mirror) nor receive a second mirror.
    function busyTargets() {
        void root.mirrorVersion
        const busy = []
        const ids = Object.keys(MirrorState.activeMirrors)
        for (let i = 0; i < ids.length; i++) {
            const mirror = MirrorState.activeMirrors[ids[i]]
            if (mirror && mirror.target) busy.push(mirror.target)
        }
        return busy
    }

    function sourceOptions() {
        const busy = busyTargets()
        return root.monitors.filter(m => busy.indexOf(m) === -1)
    }

    function targetOptions(source) {
        const busy = busyTargets()
        return root.monitors.filter(m => m !== source && busy.indexOf(m) === -1)
    }

    // Effective source: the user's pick if still valid, else the focused display
    readonly property string sourceChoice: {
        const opts = sourceOptions()
        if (opts.indexOf(selectedSource) !== -1) return selectedSource
        if (opts.indexOf(currentFocusedOutput) !== -1) return currentFocusedOutput
        return opts.length > 0 ? opts[0] : ""
    }

    // Effective target: the user's pick if still valid, else the first other display
    readonly property string targetChoice: {
        const opts = targetOptions(sourceChoice)
        if (opts.indexOf(selectedTarget) !== -1) return selectedTarget
        return opts.length > 0 ? opts[0] : ""
    }

    // Human-readable name for an output, e.g. "HP M27fw FHD" instead of "DP-4".
    // Laptop panels often report a bare hex product code, so call those "Built-in display".
    function screenLabel(name) {
        const screen = Quickshell.screens.find(s => s.name === name)
        if (/^(eDP|LVDS|DSI)/.test(name) && (!screen || !screen.model || /^0x[0-9a-f]+$/i.test(screen.model)))
            return "Built-in display"
        return (screen && screen.model) ? screen.model : name
    }

    function screenDetail(name) {
        const screen = Quickshell.screens.find(s => s.name === name)
        return screen ? (name + " · " + screen.width + "×" + screen.height) : name
    }

    // ── Identify: big click-through label on every screen for a few seconds ──
    property bool identifying: false

    function identifyMonitors() {
        root.identifying = true
        identifyTimer.restart()
    }

    Timer {
        id: identifyTimer
        interval: 2000
        onTriggered: root.identifying = false
    }

    LazyLoader {
        active: root.identifying

        Variants {
            model: Quickshell.screens

            PanelWindow {
                id: identifyWindow
                required property var modelData
                screen: modelData

                readonly property string role: modelData.name === root.sourceChoice ? "SOURCE"
                                             : modelData.name === root.targetChoice ? "TARGET" : ""

                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "dms:display-mirror-identify"
                // Never take keyboard focus and let clicks pass straight through
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                mask: Region {}

                implicitWidth: identifyCard.width
                implicitHeight: identifyCard.height

                Rectangle {
                    id: identifyCard
                    width: Math.max(identifyColumn.implicitWidth + 96, 360)
                    height: identifyColumn.implicitHeight + 64
                    radius: Theme.cornerRadius * 2
                    color: Theme.withAlpha(Theme.surfaceContainer, 0.92)
                    border.width: identifyWindow.role ? 3 : 1
                    border.color: identifyWindow.role ? Theme.primary : Theme.outline

                    Column {
                        id: identifyColumn
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: identifyWindow.modelData.name
                            font.pixelSize: 96
                            font.weight: Font.Bold
                            color: identifyWindow.role ? Theme.primary : Theme.surfaceText
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.screenLabel(identifyWindow.modelData.name)
                            font.pixelSize: 28
                            color: Theme.surfaceText
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: identifyWindow.modelData.width + "×" + identifyWindow.modelData.height
                                  + (identifyWindow.role ? "  ·  " + identifyWindow.role : "")
                            font.pixelSize: 20
                            color: Theme.surfaceVariantText
                        }
                    }
                }
            }
        }
    }

    // One selectable display row in the picker
    component MonitorRow: Rectangle {
        id: row
        property string output: ""
        property bool selected: false
        signal picked()

        height: 44
        radius: Theme.cornerRadius
        color: selected ? Theme.primaryPressed
             : rowArea.containsMouse ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.08)
             : Theme.withAlpha(Theme.surfaceContainerHighest, Theme.popupTransparency)
        border.width: selected ? 2 : 0
        border.color: Theme.primary

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingM

            DankIcon {
                name: /^(eDP|LVDS|DSI)/.test(row.output) ? "laptop" : "monitor"
                size: Theme.iconSize
                color: row.selected ? Theme.primary : Theme.surfaceVariantText
                Layout.alignment: Qt.AlignVCenter
            }

            Column {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 0

                StyledText {
                    width: parent.width
                    text: root.screenLabel(row.output)
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: row.selected ? Theme.primary : Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    width: parent.width
                    text: root.screenDetail(row.output)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            DankIcon {
                name: "check"
                size: Theme.iconSize - 4
                color: Theme.primary
                visible: row.selected
                Layout.alignment: Qt.AlignVCenter
            }
        }

        MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: row.picked()
        }
    }

    // Shared source/target picker, used by both the bar popout and the CC detail panel
    component MirrorPicker: Column {
        spacing: Theme.spacingS

        DankButton {
            width: parent.width
            text: root.identifying ? "Identifying…" : "Identify displays"
            iconName: "visibility"
            onClicked: root.identifyMonitors()
        }

        StyledText {
            text: "Source - what to show"
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceVariantText
            visible: root.sourceOptions().length > 0
        }

        Repeater {
            model: root.sourceOptions()
            delegate: MonitorRow {
                required property string modelData
                width: parent.width
                output: modelData
                selected: modelData === root.sourceChoice
                onPicked: root.selectedSource = modelData
            }
        }

        Item { width: 1; height: Theme.spacingXS }

        StyledText {
            text: "Target - where to show it"
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceVariantText
            visible: root.targetOptions(root.sourceChoice).length > 0
        }

        Repeater {
            model: root.targetOptions(root.sourceChoice)
            delegate: MonitorRow {
                required property string modelData
                width: parent.width
                output: modelData
                selected: modelData === root.targetChoice
                onPicked: root.selectedTarget = modelData
            }
        }

        Item { width: 1; height: Theme.spacingXS }

        DankButton {
            width: parent.width
            visible: root.targetChoice !== ""
            text: "Mirror " + root.sourceChoice + " → " + root.targetChoice
            iconName: "screen_share"
            onClicked: root.startMirror(root.sourceChoice, root.targetChoice)
        }

        StyledText {
            width: parent.width
            text: root.monitors.length === 0 ? "No displays found - make sure a DMS compatible compositor is running"
                                             : "No free display to mirror to"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
            visible: root.targetChoice === ""
        }
    }

    // Control Center tile properties
    ccWidgetIcon: "screen_share"
    ccWidgetPrimaryText: "Display Mirror"
    // Secondary text: show count of active mirrors or a clear no-active state
    // mirrorVersion included indirectly via hasActiveMirrors / activeMirrorCount updates, and explicit bump for reliability
    ccWidgetSecondaryText: hasActiveMirrors
        ? (activeMirrorCount + " active mirror" + (activeMirrorCount > 1 ? "s" : ""))
        : "No active mirror"
    ccWidgetIsActive: hasActiveMirrors

    onCcWidgetToggled: {
        if (hasActiveMirrors) {
            stopAllMirrors()
        }
    }

    // Listen to singleton changes to ensure tile text & info areas update immediately
    Connections {
        target: MirrorState
        function onMirrorsChanged() {
            // Force a reevaluation by bumping version counter
            mirrorVersion++
        }
    }

    Component.onCompleted: {
        checkWlMirrorInstalled()
        checkSlurpInstalled()
        refreshMonitors()
        detectFocusedOutput()
        // Pre-create the slurp result file so FileView has a stable inode to
        // watch from the start (recreating it later would break the watch)
        Quickshell.execDetached(["sh", "-c", "touch '" + root.slurpResultPath + "'"])
    }

    function checkWlMirrorInstalled() {
        wlMirrorCheckProcess.running = true
    }

    function checkSlurpInstalled() {
        slurpCheckProcess.running = true
    }

    // Best-effort label for which output a slurp region falls on (region
    // selection can span/land anywhere, this is just for display text)
    function screenForRegion(regionStr) {
        const m = regionStr.match(/^(-?\d+),(-?\d+)\s+(\d+)x(\d+)/)
        if (!m) return null
        const rx = parseInt(m[1]), ry = parseInt(m[2])
        for (let i = 0; i < Quickshell.screens.length; i++) {
            const s = Quickshell.screens[i]
            if (rx >= s.x && rx < s.x + s.width && ry >= s.y && ry < s.y + s.height) {
                return s.name
            }
        }
        return null
    }

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        repeat: true
        running: root.autoRefresh
        onTriggered: {
            root.refreshMonitors()
            root.detectFocusedOutput()
        }
    }

    function detectFocusedOutput() {
        const screen = CompositorService.getFocusedScreen()
        if (screen && screen.name) {
            root.currentFocusedOutput = screen.name
        } else {
            console.warn("DisplayMirror: Could not detect focused output")
        }
    }

    function refreshMonitors() {
        // monitors is a reactive binding on Quickshell.screens, so just re-detect which output is focused
        detectFocusedOutput()
    }

    // Mirrors `source` onto `target`. Both are chosen explicitly in the picker,
    // so this works from any screen - no need to be focused on the target.
    function startMirror(source, target) {
        if (!source || !target) return

        if (!root.wlMirrorInstalled) {
            lastMirrorError = "wl-mirror is not installed"
            Quickshell.execDetached(["sh", "-c", "notify-send 'Display Mirror' 'wl-mirror is not installed. Please install it first.' -u critical"])
            return
        }

        if (source === target) {
            lastMirrorError = "Cannot mirror a display to itself"
            return
        }

        lastMirrorError = ""

        // Close the Control Center so it doesn't stay open below the fullscreen wl-mirror window
        PopoutService.closeControlCenter()
        // Same for this widget's bar popout: left open it keeps keyboard focus until Esc
        root.closePopout()

        MirrorState.startMirror(source, target, root.scalingMode, root.scalingFilter)
    }

    // Target captured when region selection starts (the picker may change meanwhile)
    property string regionTarget: ""

    // Starts an interactive drag-select (via slurp) and mirrors just that region onto the selected target
    function startMirrorRegion() {
        if (!root.wlMirrorInstalled) {
            lastMirrorError = "wl-mirror is not installed"
            Quickshell.execDetached(["sh", "-c", "notify-send 'Display Mirror' 'wl-mirror is not installed. Please install it first.' -u critical"])
            return
        }
        if (!root.slurpInstalled) {
            lastMirrorError = "slurp is not installed"
            Quickshell.execDetached(["sh", "-c", "notify-send 'Display Mirror' 'slurp is not installed. Please install it first.' -u critical"])
            return
        }
        if (!root.targetChoice) {
            lastMirrorError = "No target display selected"
            return
        }

        root.regionTarget = root.targetChoice

        // Close popouts first so they don't obstruct (or steal input from) the
        // region-selection overlay - give the close animation a moment to finish
        PopoutService.closeControlCenter()
        slurpLaunchDelay.start()
    }

    function onRegionSelected(regionStr) {
        const targetOutput = root.regionTarget
        if (!targetOutput) {
            lastMirrorError = "No target display selected"
            return
        }

        const sourceLabel = screenForRegion(regionStr) || "Selection"
        if (sourceLabel === targetOutput) {
            lastMirrorError = "Cannot mirror a region of " + targetOutput + " onto itself"
            return
        }

        lastMirrorError = ""
        MirrorState.startMirror(sourceLabel, targetOutput, root.scalingMode, root.scalingFilter, regionStr)
    }

    function stopMirror(id) {
        MirrorState.stopMirror(id)
    }

    function stopAllMirrors() {
        MirrorState.stopAllMirrors()
    }

    // Adjusts scaling live on a running mirror (no restart), via MirrorState/wl-mirror's --stream mode
    function setMirrorScaling(id, mode, filter) {
        MirrorState.setScaling(id, mode, filter)
    }

    // Adjusts zoom live on a running mirror (no restart). zoomPercent is 100-200 (1x-2x).
    function setMirrorZoom(id, zoomPercent) {
        MirrorState.setZoom(id, zoomPercent)
    }

    Process {
        id: wlMirrorCheckProcess
        command: ["sh", "-c", "command -v wl-mirror"]
        running: false

        stdout: SplitParser {
            onRead: data => {
                if (data.trim().length > 0) {
                    root.wlMirrorInstalled = true
                    console.log("DisplayMirror: wl-mirror is installed at:", data.trim())
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.wlMirrorInstalled = false
                console.warn("DisplayMirror: wl-mirror is not installed")
            }
        }
    }

    Process {
        id: slurpCheckProcess
        command: ["sh", "-c", "command -v slurp"]
        running: false

        stdout: SplitParser {
            onRead: data => {
                if (data.trim().length > 0) {
                    root.slurpInstalled = true
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.slurpInstalled = false
                console.warn("DisplayMirror: slurp is not installed")
            }
        }
    }

    // slurp must run as a fully detached process (like screenRecorderLH does), not
    // as a Quickshell-managed child - a managed Process's selection overlay does
    // not reliably get keyboard/pointer focus from the compositor. Since detached
    // processes have no stdout capture, the result is written to a file instead
    // and picked up here via a watched FileView.
    readonly property string slurpResultPath: "/tmp/dms-display-mirror-region.txt"
    property bool awaitingRegionResult: false

    FileView {
        id: slurpResultFile
        path: root.slurpResultPath
        watchChanges: true

        function tryConsume() {
            if (!root.awaitingRegionResult)
                return
            const region = text().trim()
            console.warn("DisplayMirror: slurp result file contains:", JSON.stringify(region))
            if (region.length === 0)
                return
            root.awaitingRegionResult = false
            root.onRegionSelected(region)
        }

        onLoaded: tryConsume()
        onLoadFailed: error => console.warn("DisplayMirror: could not read slurp result file:", error)
        onFileChanged: reload()
    }

    Timer {
        id: slurpLaunchDelay
        interval: 200
        onTriggered: {
            root.awaitingRegionResult = true
            console.warn("DisplayMirror: launching detached slurp")
            Quickshell.execDetached(["sh", "-c", "slurp > '" + root.slurpResultPath + "'"])
        }
    }

    // Provide bar pills so widget is visible if added to DankBar (even though capability is control-center)
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            DankIcon {
                name: "screen_share"
                size: Theme.iconSize - 6
                color: root.hasActiveMirrors ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: root.hasActiveMirrors ? (root.activeMirrorCount + " active") : ""
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
                visible: root.hasActiveMirrors
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            DankIcon {
                name: "screen_share"
                size: Theme.iconSize - 6
                color: root.hasActiveMirrors ? Theme.primary : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }
            StyledText {
                text: root.hasActiveMirrors ? root.activeMirrorCount : ""
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
                rotation: 90
                visible: root.hasActiveMirrors
            }
        }
    }

    // Popout used when user clicks pill (bar)
    popoutContent: Component {
        PopoutComponent {
            id: detailPopout

            headerText: "Display Mirror"
            detailsText: hasActiveMirrors ? (activeMirrorCount + " display" + (activeMirrorCount > 1 ? "s" : "") + " currently being mirrored.") : "Pick a source and a target display"
            showCloseButton: true

            onVisibleChanged: {
                if (visible) {
                    root.checkWlMirrorInstalled()
                    root.detectFocusedOutput()
                }
            }

            Component.onCompleted: {
                root.checkWlMirrorInstalled()
                root.detectFocusedOutput()
            }

            // Refresh + region-select buttons
            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankButton {
                    width: (parent.width - Theme.spacingS) / 2
                    text: "Refresh"
                    iconName: "refresh"
                    onClicked: root.refreshMonitors()
                }

                DankButton {
                    width: (parent.width - Theme.spacingS) / 2
                    text: "Select Region"
                    iconName: "crop"
                    onClicked: {
                        // Close this popout first - it can otherwise sit on top of (and
                        // intercept input meant for) slurp's selection overlay
                        detailPopout.closePopout?.()
                        root.startMirrorRegion()
                    }
                }
            }

            Item {
                width: 1
                height: Theme.spacingS
            }

            // wl-mirror not installed warning
            StyledRect {
                width: parent.width
                height: wlMirrorWarningColumn.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.errorContainer || Theme.surfaceContainerHigh
                visible: !root.wlMirrorInstalled

                Column {
                    id: wlMirrorWarningColumn
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingS

                    Row {
                        spacing: Theme.spacingM
                        width: parent.width

                        DankIcon {
                            name: "warning"
                            size: Theme.iconSize
                            color: Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "wl-mirror Not Installed"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    StyledText {
                        text: "The wl-mirror utility is required for display mirroring but is not installed on your system."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        wrapMode: Text.WordWrap
                        width: parent.width
                        lineHeight: 1.3
                    }
                }
            }

            Item {
                width: 1
                height: Theme.spacingS
                visible: !root.wlMirrorInstalled
            }

            Item {
                width: 1
                height: Theme.spacingS
                visible: root.hasActiveMirrors
            }

            // Active mirrors section
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.hasActiveMirrors

                Repeater {
                    model: Object.keys(MirrorState.activeMirrors)

                    delegate: Rectangle {
                        required property var modelData
                        required property int index

                        width: parent.width
                        height: mirrorCardColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.primaryPressed
                        border.width: 2
                        border.color: Theme.primary

                        Column {
                            id: mirrorCardColumn
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                id: mirrorStatusRow
                                width: parent.width
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "screen_share"
                                    size: Theme.iconSize
                                    color: Theme.primary
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                Column {
                                    spacing: 2
                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.fillWidth: true

                                    StyledText {
                                        text: {
                                            const mirror = root.activeMirrors[modelData]
                                            return mirror ? (root.screenLabel(mirror.source) + " → " + root.screenLabel(mirror.target)) : "Unknown"
                                        }
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.primary
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                        width: parent.width
                                    }

                                    StyledText {
                                        text: {
                                            const mirror = root.activeMirrors[modelData]
                                            return mirror ? (mirror.source + " → " + mirror.target + (mirror.pid ? "  ·  PID " + mirror.pid : "  ·  starting…")) : ""
                                        }
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceTextMedium
                                    }
                                }

                                DankButton {
                                    text: "Stop"
                                    iconName: "stop"
                                    onClicked: root.stopMirror(modelData)
                                    Layout.alignment: Qt.AlignVCenter
                                }
                            }

                            // Live scaling controls - applied immediately to the running mirror.
                            // Stacked (not side-by-side) so labels never get squeezed/cut off.
                            Column {
                                width: parent.width
                                spacing: Theme.spacingXS

                                DankButtonGroup {
                                    model: root.scalingModeLabels
                                    size: "small"
                                    checkEnabled: false
                                    maximumWidth: parent.width
                                    currentIndex: root.scalingModeValues.indexOf((root.activeMirrors[modelData] && root.activeMirrors[modelData].scalingMode) || "fit")
                                    onSelectionChanged: (idx, selected) => {
                                        if (!selected) return
                                        const mirror = root.activeMirrors[modelData]
                                        root.setMirrorScaling(modelData, root.scalingModeValues[idx], mirror ? mirror.scalingFilter : "linear")
                                    }
                                }

                                DankButtonGroup {
                                    model: root.scalingFilterLabels
                                    size: "small"
                                    checkEnabled: false
                                    maximumWidth: parent.width
                                    currentIndex: root.scalingFilterValues.indexOf((root.activeMirrors[modelData] && root.activeMirrors[modelData].scalingFilter) || "linear")
                                    onSelectionChanged: (idx, selected) => {
                                        if (!selected) return
                                        const mirror = root.activeMirrors[modelData]
                                        root.setMirrorScaling(modelData, mirror ? mirror.scalingMode : "fit", root.scalingFilterValues[idx])
                                    }
                                }

                                // Continuous digital zoom (1x-2x): crops a centered region of the
                                // source and lets the scaling mode above stretch it to fill the target
                                DankSlider {
                                    id: zoomSlider
                                    width: parent.width
                                    minimum: 100
                                    maximum: 200
                                    step: 5
                                    unit: "%"
                                    leftIcon: "zoom_out"
                                    rightIcon: "zoom_in"
                                    // Zoom crops a centered region of the whole source display; doesn't
                                    // compose with a mirror that already started from a custom region
                                    visible: !(root.activeMirrors[modelData] && root.activeMirrors[modelData].region)
                                    onSliderValueChanged: newValue => root.setMirrorZoom(modelData, newValue)
                                    onSliderDragFinished: finalValue => root.setMirrorZoom(modelData, finalValue)

                                    Binding on value {
                                        value: Math.round(((root.activeMirrors[modelData] && root.activeMirrors[modelData].zoom) || 1) * 100)
                                        when: !zoomSlider.isDragging
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Item {
                width: 1
                height: Theme.spacingS
            }

            // Source / target picker (all monitors, independent of focus)
            MirrorPicker {
                width: parent.width
                visible: root.wlMirrorInstalled
            }

            // Error display
            StyledRect {
                width: parent.width
                height: errorColumn.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                visible: root.lastMirrorError !== ""

                Column {
                    id: errorColumn
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingS

                    Row {
                        spacing: Theme.spacingM

                        DankIcon {
                            name: "error"
                            size: Theme.iconSize
                            color: Theme.warning || Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "Mirror Error"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }
                    }

                    StyledText {
                        text: root.lastMirrorError
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        leftPadding: Theme.iconSize + Theme.spacingM
                        width: parent.width - Theme.spacingM * 2
                    }
                }
            }
        }
    }    // Control Center detail panel (when clicking the CC tile arrow/chevron)
    ccDetailContent: Component {
        Rectangle {
            implicitHeight: Math.min(headerRow.height + contentFlickable.contentHeight + Theme.spacingM * 2, 400 + headerRow.height)
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
            border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.08)
            border.width: 0

            Row {
                id: headerRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                anchors.topMargin: Theme.spacingS
                height: 40

                StyledText {
                    id: headerText
                    text: "Display Mirror"
                    font.pixelSize: Theme.fontSizeLarge
                    color: Theme.surfaceText
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    width: Math.max(0, parent.width - headerText.implicitWidth - refreshButton.width - Theme.spacingM)
                    height: parent.height
                }

                DankButton {
                    id: refreshButton
                    text: "Refresh"
                    iconName: "refresh"
                    onClicked: {
                        root.refreshMonitors()
                        root.detectFocusedOutput()
                    }
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            DankFlickable {
                id: contentFlickable
                anchors.top: headerRow.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.topMargin: Theme.spacingM
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                anchors.bottomMargin: Theme.spacingM
                contentHeight: ccContentColumn.implicitHeight
                clip: true

                Column {
                    id: ccContentColumn
                    width: parent.width
                    spacing: Theme.spacingM

                // Region-select button
                DankButton {
                    width: parent.width
                    text: "Select Region to Mirror"
                    iconName: "crop"
                    onClicked: root.startMirrorRegion()
                }

                // wl-mirror not installed warning
                StyledRect {
                    width: parent.width
                    height: wlMirrorWarningColumnCC.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.errorContainer || Theme.surfaceContainerHigh
                    visible: !root.wlMirrorInstalled

                    Column {
                        id: wlMirrorWarningColumnCC
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        Row {
                            spacing: Theme.spacingM
                            width: parent.width

                            DankIcon {
                                name: "warning"
                                size: Theme.iconSize
                                color: Theme.error
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: "wl-mirror Not Installed"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.error
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        StyledText {
                            text: "The wl-mirror utility is required for display mirroring but is not installed on your system."
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            wrapMode: Text.WordWrap
                            width: parent.width
                            lineHeight: 1.3
                        }
                    }
                }

                // Info text (CC detail)
                StyledText {
                    width: parent.width - Theme.spacingM * 2
                    text: hasActiveMirrors ? (activeMirrorCount + " display" + (activeMirrorCount > 1 ? "s" : "") + " currently being mirrored.") : "Pick a source and a target display"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    visible: root.wlMirrorInstalled
                    bottomPadding: Theme.spacingS
                }

                // Active mirror status boxes (one per mirror) - shown above available displays
                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    Repeater {
                        model: Object.keys(MirrorState.activeMirrors)

                        delegate: Rectangle {
                            required property var modelData
                            required property int index

                            width: parent.width
                            height: mirrorCardColumnCC.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.primaryPressed
                            border.width: 2
                            border.color: Theme.primary

                            Column {
                                id: mirrorCardColumnCC
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                RowLayout {
                                    id: mirrorRowCCDetail
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "screen_share"
                                        size: Theme.iconSize
                                        color: Theme.primary
                                        Layout.alignment: Qt.AlignVCenter
                                    }

                                    Column {
                                        spacing: 2
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.fillWidth: true

                                        StyledText {
                                            text: {
                                                const mirror = root.activeMirrors[modelData]
                                                return mirror ? (root.screenLabel(mirror.source) + " → " + root.screenLabel(mirror.target)) : "Unknown"
                                            }
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.primary
                                            elide: Text.ElideRight
                                            wrapMode: Text.NoWrap
                                            width: parent.width
                                        }

                                        StyledText {
                                            text: {
                                                const mirror = root.activeMirrors[modelData]
                                                return mirror ? (mirror.source + " → " + mirror.target + (mirror.pid ? "  ·  PID " + mirror.pid : "  ·  starting…")) : ""
                                            }
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceTextMedium
                                        }
                                    }

                                    DankButton {
                                        id: stopButtonCCDetail
                                        text: "Stop"
                                        iconName: "stop"
                                        onClicked: root.stopMirror(modelData)
                                        Layout.alignment: Qt.AlignVCenter
                                    }
                                }

                                // Live scaling controls - applied immediately to the running mirror.
                                // Stacked (not side-by-side) so labels never get squeezed/cut off.
                                Column {
                                    width: parent.width
                                    spacing: Theme.spacingXS

                                    DankButtonGroup {
                                        model: root.scalingModeLabels
                                        size: "small"
                                        checkEnabled: false
                                        maximumWidth: parent.width
                                        currentIndex: root.scalingModeValues.indexOf((root.activeMirrors[modelData] && root.activeMirrors[modelData].scalingMode) || "fit")
                                        onSelectionChanged: (idx, selected) => {
                                            if (!selected) return
                                            const mirror = root.activeMirrors[modelData]
                                            root.setMirrorScaling(modelData, root.scalingModeValues[idx], mirror ? mirror.scalingFilter : "linear")
                                        }
                                    }

                                    DankButtonGroup {
                                        model: root.scalingFilterLabels
                                        size: "small"
                                        checkEnabled: false
                                        maximumWidth: parent.width
                                        currentIndex: root.scalingFilterValues.indexOf((root.activeMirrors[modelData] && root.activeMirrors[modelData].scalingFilter) || "linear")
                                        onSelectionChanged: (idx, selected) => {
                                            if (!selected) return
                                            const mirror = root.activeMirrors[modelData]
                                            root.setMirrorScaling(modelData, mirror ? mirror.scalingMode : "fit", root.scalingFilterValues[idx])
                                        }
                                    }

                                    // Continuous digital zoom (1x-2x): crops a centered region of the
                                    // source and lets the scaling mode above stretch it to fill the target
                                    DankSlider {
                                        id: zoomSliderCC
                                        width: parent.width
                                        minimum: 100
                                        maximum: 200
                                        step: 5
                                        unit: "%"
                                        leftIcon: "zoom_out"
                                        rightIcon: "zoom_in"
                                        visible: !(root.activeMirrors[modelData] && root.activeMirrors[modelData].region)
                                        onSliderValueChanged: newValue => root.setMirrorZoom(modelData, newValue)
                                        onSliderDragFinished: finalValue => root.setMirrorZoom(modelData, finalValue)

                                        Binding on value {
                                            value: Math.round(((root.activeMirrors[modelData] && root.activeMirrors[modelData].zoom) || 1) * 100)
                                            when: !zoomSliderCC.isDragging
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Error display
                    StyledRect {
                        width: parent.width
                        height: errorColumnCCDetail.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh
                        visible: root.lastMirrorError !== ""

                        Column {
                            id: errorColumnCCDetail
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "error"
                                    size: Theme.iconSize
                                    color: Theme.warning || Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Mirror Error"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            StyledText {
                                text: "Attempted to start mirror. " + (root.lastMirrorError || "Unknown issue.")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                                leftPadding: Theme.iconSize + Theme.spacingM
                                width: parent.width - Theme.spacingM * 2
                            }
                        }
                    }
                }

                // Source / target picker (all monitors, independent of focus)
                MirrorPicker {
                    width: parent.width
                    visible: root.wlMirrorInstalled
                }
            }
        }
        }
    }

    popoutWidth: 400
}
