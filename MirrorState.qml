import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Singleton to share mirror state across all widget instances, and to own
// the actual wl-mirror processes so scaling can be adjusted live (via
// wl-mirror's --stream stdin protocol) regardless of which widget instance
// (bar or control center) is currently open.
pragma Singleton

QtObject {
    id: root

    // Active mirrors keyed by a locally-generated id (NOT the OS pid) so an
    // entry can exist - and drive the Instantiator below - before the real
    // process/pid exists.
    // { id: { source, target, scalingMode, scalingFilter, zoom, pid } }
    property var activeMirrors: ({})
    property int _nextId: 1
    property var _handles: ({})  // id -> Process, used by stopMirror()/setScaling()

    readonly property bool hasActiveMirrors: Object.keys(activeMirrors).length > 0
    readonly property int activeMirrorCount: Object.keys(activeMirrors).length
    property string lastError: ""

    signal mirrorsChanged()

    onActiveMirrorsChanged: {
        console.log("MirrorState: activeMirrors changed, count:", Object.keys(activeMirrors).length)
        mirrorsChanged()
    }

    function _validScalingMode(mode) {
        return ["fit", "cover", "exact"].indexOf(mode) !== -1 ? mode : "fit"
    }

    function _validScalingFilter(filter) {
        return ["linear", "nearest"].indexOf(filter) !== -1 ? filter : "linear"
    }

    function _findScreen(name) {
        const screens = Quickshell.screens
        for (let i = 0; i < screens.length; i++) {
            if (screens[i].name === name)
                return screens[i]
        }
        return null
    }

    // Registers a new mirror and returns its id. The actual wl-mirror
    // process is spawned by the Instantiator below once the id appears in
    // activeMirrors. `region`, when given, is a slurp-format "x,y wxh"
    // string (in the source output's coordinate space) restricting the
    // mirror to that sub-area instead of the whole output.
    function startMirror(source, target, scalingMode, scalingFilter, region) {
        const id = "m" + (_nextId++)
        const mirrors = Object.assign({}, activeMirrors)
        mirrors[id] = {
            source: source,
            target: target,
            scalingMode: _validScalingMode(scalingMode),
            scalingFilter: _validScalingFilter(scalingFilter),
            region: region || null,
            zoom: 1,
            pid: 0
        }
        activeMirrors = mirrors
        return id
    }

    function stopMirror(id) {
        const proc = _handles[id]
        if (proc) {
            proc.signal(15)  // SIGTERM; cleanup happens in onExited
        }
    }

    function stopAllMirrors() {
        const ids = Object.keys(activeMirrors)
        for (let i = 0; i < ids.length; i++) {
            stopMirror(ids[i])
        }
    }

    // Adjusts scaling on a running mirror live, via wl-mirror's --stream
    // stdin protocol - no restart required.
    function setScaling(id, scalingMode, scalingFilter) {
        const mirror = activeMirrors[id]
        const proc = _handles[id]
        if (!mirror || !proc)
            return

        const mode = _validScalingMode(scalingMode)
        const filter = _validScalingFilter(scalingFilter)
        if (mode === mirror.scalingMode && filter === mirror.scalingFilter)
            return

        proc.write("--scaling " + mode + " --scaling " + filter + "\n")
        console.log("MirrorState: sent live scaling update to PID", mirror.pid, "-", mode, filter)

        const mirrors = Object.assign({}, activeMirrors)
        mirrors[id] = Object.assign({}, mirror, {scalingMode: mode, scalingFilter: filter})
        activeMirrors = mirrors
    }

    // Adjusts zoom on a running mirror live. wl-mirror has no direct zoom
    // factor, so this crops a centered region of the SOURCE display and
    // relies on the existing scaling mode to stretch it back to fill the
    // target - a real continuous digital zoom, sent over the same --stream
    // stdin protocol as setScaling().
    function setZoom(id, zoomPercent) {
        const mirror = activeMirrors[id]
        const proc = _handles[id]
        if (!mirror || !proc)
            return

        const zoom = Math.max(100, Math.min(200, Math.round(zoomPercent))) / 100
        if (zoom === (mirror.zoom || 1))
            return

        if (zoom <= 1.001) {
            proc.write("--no-region\n")
        } else {
            const screen = _findScreen(mirror.source)
            if (!screen)
                return
            const w = Math.max(1, Math.round(screen.width / zoom))
            const h = Math.max(1, Math.round(screen.height / zoom))
            const x = Math.round((screen.width - w) / 2)
            const y = Math.round((screen.height - h) / 2)
            proc.write("--region '" + x + "," + y + " " + w + "x" + h + " " + mirror.source + "'\n")
        }
        console.log("MirrorState: sent live zoom update to PID", mirror.pid, "-", Math.round(zoom * 100) + "%")

        const mirrors = Object.assign({}, activeMirrors)
        mirrors[id] = Object.assign({}, mirror, {zoom: zoom})
        activeMirrors = mirrors
    }

    // mango ignores the output requested via xdg_toplevel.set_fullscreen and
    // opens the mirror on the focused monitor. Wait for the window to map, move
    // it to the target with tagmon, then return focus to the monitor it came
    // from (tagmon makes focus follow the window).
    function _placeOnMango(pid, target) {
        const script = 'pid="$1"; target="$2"\n'
            + 'command -v mmsg >/dev/null && command -v jq >/dev/null || exit 0\n'
            + 'for _ in $(seq 1 50); do\n'
            + '  c=$(mmsg get all-clients | jq -c --argjson p "$pid" \'(.clients // .)[] | select(.pid == $p) | {id, monitor}\' | head -n1)\n'
            + '  [ -n "$c" ] && break; sleep 0.1\n'
            + 'done\n'
            + '[ -n "$c" ] || exit 0\n'
            + 'id=$(printf "%s" "$c" | jq -r .id); from=$(printf "%s" "$c" | jq -r .monitor)\n'
            + '[ "$from" = "$target" ] && exit 0\n'
            + 'mmsg dispatch "tagmon,$target" "client,$id" >/dev/null\n'
            + 'mmsg dispatch "focusmon,$from" >/dev/null\n'
        Quickshell.execDetached(["sh", "-c", script, "dms-mirror-place", String(pid), target])
    }

    function _setPid(id, pid) {
        const mirror = activeMirrors[id]
        if (!mirror || mirror.pid === pid)
            return
        const wasStarting = !mirror.pid
        const mirrors = Object.assign({}, activeMirrors)
        mirrors[id] = Object.assign({}, mirror, {pid: pid})
        activeMirrors = mirrors
        if (wasStarting && pid) {
            Quickshell.execDetached(["sh", "-c", "notify-send 'Display Mirror' 'Now mirroring " + mirror.source + " → " + mirror.target + "' -u low"])
        }
    }

    function _onProcessExited(id, exitCode) {
        const mirror = activeMirrors[id]
        delete _handles[id]
        if (!mirror)
            return
        const mirrors = Object.assign({}, activeMirrors)
        delete mirrors[id]
        activeMirrors = mirrors

        if (!mirror.pid) {
            root.lastError = "Failed to start wl-mirror (exit " + exitCode + ")"
            Quickshell.execDetached(["sh", "-c", "notify-send 'Display Mirror' 'Failed to start mirror' -u critical"])
        } else {
            Quickshell.execDetached(["sh", "-c", "notify-send 'Display Mirror' 'Stopped mirroring " + mirror.source + " → " + mirror.target + "' -u low"])
        }
    }

    // QtObject has no default "data" property (unlike Item), so the
    // Instantiator must be attached explicitly via a named property.
    property Instantiator _procInstantiator: Instantiator {
        model: ScriptModel {
            values: Object.keys(root.activeMirrors)
        }

        delegate: Process {
            id: proc
            required property string modelData
            stdinEnabled: true

            stderr: SplitParser {
                onRead: data => {
                    if (data.trim().length > 0)
                        console.warn("MirrorState: wl-mirror[" + proc.modelData + "]:", data.trim())
                }
            }

            Component.onCompleted: {
                const info = root.activeMirrors[modelData]
                if (!info)
                    return
                // --fullscreen-output puts the mirror on the chosen target instead
                // of whichever display is focused (honoured by sway/niri/hyprland;
                // mango ignores it, see _placeOnMango)
                const args = ["wl-mirror", "--stream",
                              "--fullscreen-output", info.target,
                              "--scaling", info.scalingMode,
                              "--scaling", info.scalingFilter]
                if (info.region) {
                    args.push("--region", info.region)
                } else {
                    args.push(info.source)
                }
                command = args
                root._handles[modelData] = proc
                running = true
            }

            onProcessIdChanged: {
                if (!processId)
                    return
                root._setPid(modelData, processId)
                const info = root.activeMirrors[modelData]
                if (info && CompositorService.isMango)
                    root._placeOnMango(processId, info.target)
            }

            onExited: (exitCode, exitStatus) => {
                root._onProcessExited(modelData, exitCode)
            }
        }
    }
}
