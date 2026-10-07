import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill: a plane and how many aircraft are in the air within the overhead
// radius of your location. Click opens the globe, middle click the Look up
// lens, right click refreshes. The text changes at most once per feed update
// and never on a timer of its own. The plane keeps the colour of the other bar
// icons; only an emergency squawk overhead switches it to the alert colour.
BarWidget {
  id: root
  moduleName: "io.github.pedroolivy.flightline"

  // The service is created by the shell when the plugin is enabled and can
  // be recreated on hot reload, so look it up until it is there.
  property var service: null
  function lookupService() {
    var shell = root.bar && root.bar.shell ? root.bar.shell : null
    var s = shell && typeof shell.serviceFor === "function" ? shell.serviceFor(root.moduleName) : null
    if (s !== service) service = s
  }
  Timer {
    interval: 400
    repeat: true
    running: !root.service
    triggeredOnStart: true
    onTriggered: root.lookupService()
  }
  onBarChanged: lookupService()
  onServiceChanged: pushSettings()
  onSettingsChanged: pushSettings()

  function pushSettings() {
    if (service) service.settings = root.settings || ({})
    injectPanel()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  // Shape contract for shell.summon/hide/toggle routing (the bar looks for
  // open/close/opened on the widget root), same as Omarchy's weather pill.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property int count: service && service.hasHome ? service.nearbyCount : -1
  // The count comes from the last answer that covered the overhead circle.
  // With the panel open somewhere else it can grow old; checked on every
  // feed update, so no timer of its own.
  readonly property bool stale: !!service && service.nearbyMs > 0 && service.lastUpdateMs - service.nearbyMs > 300000
  readonly property string units: service ? service.units : "metric"

  // An emergency squawk inside the overhead circle outranks the count.
  readonly property var alert: {
    if (!service || !service.hasHome) return null
    var list = service.emergencies || []
    var reach = service.nearbyRadiusNm * Model.NM_KM
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      var km = Model.distanceKm(service.home.lat, service.home.lon, e.lat, e.lon)
      if (km <= reach) return { row: e, km: km, brg: Model.bearingDeg(service.home.lat, service.home.lon, e.lat, e.lon) }
    }
    return null
  }

  // Same look as Omarchy's own bar icons: one icon slot for the plane, a second
  // one (a third for a long squawk) while it carries a count or an emergency.
  readonly property string planeIcon: "󰀝"
  readonly property string badge: alert ? (alert.row.sq || "SOS") : (count > 0 ? String(count) : "")
  readonly property string label: planeIcon + (badge !== "" ? " " + badge : "")

  function routeText(cs) {
    var r = cs && service && service.routes.hasOwnProperty(cs) ? service.routes[cs] : null
    return r ? r.origin.code + "→" + r.destination.code : ""
  }

  readonly property string tooltip: {
    if (!service) return "Flightline"
    if (!service.hasHome) return "Flightline · set your location"
    var radius = Model.formatRadius(service.nearbyRadiusNm, units)
    if (service.status === "error" && count < 0) return "Flightline · traffic feed unreachable"
    if (count < 0) return "Flightline · listening…"
    var lines = [(count === 0 ? "No aircraft" : (count === 1 ? "1 aircraft" : count + " aircraft")) + " within " + radius
                 + (stale ? " · as of " + Qt.formatTime(new Date(service.nearbyMs), "hh:mm") : "")]
    if (alert) {
      var a = alert.row
      lines.push("Emergency  " + (a.cs || a.hex.toUpperCase()) + " squawks " + (a.sq || "an emergency") + " · "
        + Model.formatDistance(alert.km, units) + " " + Model.compassPoint(alert.brg))
    }
    var n = service.nearest.length > 0 ? service.nearest[0] : null
    if (n) {
      var ac = Model.toAircraft(n, NaN)
      var parts = [Model.displayName(ac), n.ty, routeText(n.cs),
                   Model.formatDistance(n.km, units) + " " + Model.compassPoint(n.brg), Model.formatAltitude(ac, units)]
      lines.push("Nearest  " + parts.filter(function(s) { return s }).join(" · "))
    }
    if (service.worldCount >= 0) lines.push("World  " + Model.groupThousands(service.worldCount) + " airborne")
    return lines.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical || root.badge === "" ? root.planeIcon : root.label
    slotSize: Style.bar.iconSlot * (root.vertical || root.badge === "" ? 1 : (root.badge.length <= 3 ? 2 : 3))
    active: root.alert !== null
    tooltipText: root.opened ? "" : root.tooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.service) root.service.refresh() }
      else if (b === Qt.MiddleButton) { if (panelLoader.item) panelLoader.item.openLens("lookup") }
      else root.toggle()
    }
  }
}
