import QtQuick
import Quickshell
import qs.Ui

BarWidget {
  id: root
  moduleName: "costafot.autoduck"

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("costafot.autoduck") : null
  readonly property bool serviceEnabled: svc ? svc.enabled : false
  readonly property bool ducked: svc ? svc.ducked : false

  visible: svc !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰇥"
    active: root.ducked
    opacity: root.serviceEnabled ? 1 : 0.45
    tooltipText: !root.serviceEnabled
      ? "Autoduck off — click to arm"
      : root.ducked
        ? "Music muted while another tab plays"
        : "Autoduck armed — music mutes when another tab plays audio"
    onPressed: function () {
      if (root.svc) root.svc.toggle()
    }
  }
}
