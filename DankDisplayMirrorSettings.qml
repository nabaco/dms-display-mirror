import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "displayMirror"

    StyledText {
        width: parent.width
    text: "Display Mirror Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
    text: "Configure display mirroring behavior"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: refreshColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: refreshColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Monitor Detection"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            ToggleSetting {
                settingKey: "autoRefresh"
                label: "Auto-refresh Monitor List"
                description: "Automatically update the list of available monitors (disabled by default to avoid visual glitches)"
                defaultValue: false
            }

            StringSetting {
                settingKey: "refreshInterval"
                label: "Refresh Interval (seconds)"
                description: "How often to check for monitor changes"
                placeholder: "30"
                defaultValue: "30"
            }
        }
    }

    StyledRect {
        width: parent.width
        height: scalingColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: scalingColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Mirror Scaling"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            SelectionSetting {
                settingKey: "scalingMode"
                label: "Scaling Mode"
                description: "How the source display's content fits the target display"
                defaultValue: "fit"
                options: [
                    { label: "Fit (letterbox)", value: "fit" },
                    { label: "Cover (crop)", value: "cover" },
                    { label: "Exact (pixel-perfect)", value: "exact" }
                ]
            }

            SelectionSetting {
                settingKey: "scalingFilter"
                label: "Scaling Filter"
                description: "Algorithm used when scaling the image"
                defaultValue: "linear"
                options: [
                    { label: "Linear (smooth)", value: "linear" },
                    { label: "Nearest Neighbor (sharp/pixelated)", value: "nearest" }
                ]
            }
        }
    }

    StyledRect {
        width: parent.width
        height: infoColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surface

        Column {
            id: infoColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                spacing: Theme.spacingM

                DankIcon {
                    name: "info"
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "About Display Mirror"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                text: "This plugin allows you to mirror displays using wl-mirror. It's particularly useful for screen sharing or duplicating your screen.\n\nThe Mirror Scaling settings above set the default for new mirrors. Each active mirror shown in the Control Center or bar popout also has its own live controls:\n• Fit / Cover / Exact — how the image fits the target display\n• Linear / Nearest — smooth vs. sharp scaling\n• Zoom (1x-2x) — crops into the center of the source display (whole-display mirrors only)\n\nAll of these apply instantly to the running mirror, no restart needed.\n\n'Select Region' lets you drag-select any custom area to mirror instead of a whole display (requires slurp). Region mirrors don't have the Zoom slider since the region itself is your crop.\n\nRequirements:\n• wl-mirror (install via package manager)\n• slurp (optional, only needed for 'Select Region')\n• A DMS-supported compositor (niri, Hyprland, sway, dwl, …)\n• Wayland session\n\nUsage:\n1. Open Control Center\n2. Click the Display Mirror tile\n3. Select a display, or click 'Select Region' to drag-select a custom area\n4. A new window will open showing the mirrored content\n5. Click 'Stop Mirror' to end the session"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                width: parent.width
                lineHeight: 1.4
            }
        }
    }

    StyledRect {
        width: parent.width
        height: commandsColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: commandsColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                spacing: Theme.spacingM

                DankIcon {
                    name: "terminal"
                    size: Theme.iconSize
                    color: Theme.warning
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "Manual Commands"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                text: "To manually control wl-mirror:\n\nList outputs:\n  dms randr\n\nStart mirroring:\n  wl-mirror <output-name>\n\nStop all mirrors:\n  killall wl-mirror"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                width: parent.width
                lineHeight: 1.4
                font.family: "monospace"
            }
        }
    }
}
