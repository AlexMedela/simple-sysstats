pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// View modes shared by every widget instance, so the same stat on different
// screens stays in sync. Keyed by stat (and mount point for disks) and saved
// to disk so the choice survives restarts.
Singleton {
  id: root

  property var modes: ({})

  function setMode(key, mode) {
    var next = ({})
    for (var k in modes) next[k] = modes[k]
    next[key] = mode
    modes = next
    stateFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function load(text) {
    try {
      var data = JSON.parse(text)
      if (data && typeof data === "object") modes = data
    } catch (e) {}
  }

  FileView {
    id: stateFile
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/amedela.simple-sysstats.json"
    blockLoading: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.load(text())
  }
}
