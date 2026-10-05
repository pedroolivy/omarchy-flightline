import QtQuick
import QtQuick.Window
import "../.."

// The lens does nothing while nothing changes: it scans and paints once, then
// again only on the 10 s tick, a new traffic revision, a selection or a
// hidden/shown toggle. Prints the counters every second for 12 s and checks
// them at the end (exit code 1 on a mismatch). Needs lookup.sh's meta.json.
Window {
  id: win
  width: 600
  height: 560
  visible: true
  color: "#1a1b26"

  readonly property string dataDir: Qt.application.arguments[Qt.application.arguments.indexOf("--") + 1] + "/lookup-data"
  readonly property var metaData: {
    var xhr = new XMLHttpRequest()
    xhr.open("GET", "file://" + dataDir + "/meta.json", false)
    xhr.send()
    return JSON.parse(xhr.responseText)
  }

  QtObject {
    id: mock
    property int trafficRev: 1
    property double epochMs: win.metaData.epochMs
    property var lastQuery: null
    property string status: "ok"
    function meta() { return win.metaData }
  }

  LookUp {
    id: look
    anchors.fill: parent
    service: mock
    fixedNowMs: win.metaData.epochMs + 305000
    tickMs: 6500                        // the tick lands between the events below
    home: ({ lat: 51.47, lon: -0.45 })
  }

  property int seconds: 0
  property var log: []
  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      win.seconds++
      win.log.push(look.paintCount + "/" + look.scanCount)
      console.info("t=" + win.seconds + " paints/scans " + look.paintCount + "/" + look.scanCount)
      if (win.seconds === 4) mock.trafficRev = 2          // a new feed answer
      if (win.seconds === 6) look.selectedIndex = look.skyCount > 0 ? look.scan.sky[0].i : -1
      if (win.seconds === 8) look.visible = false          // panel closed or another lens
      if (win.seconds === 10) look.visible = true
      if (win.seconds === 12) {
        // t=1: the first scan and its paints; t=3: unchanged; t=5: +1 scan and paint for the
        // revision; t=7: +1 scan and paint for the 6.5 s tick (and the selection paints at t=6);
        // t=9: nothing while hidden; t=11: shown again, +1 scan
        var c = win.log.map(function (s) { return s.split("/").map(Number) })
        var ok = c[2][1] === c[0][1] && c[2][0] === c[0][0]
          && c[4][1] === c[2][1] + 1 && c[4][0] === c[2][0] + 1
          && c[6][1] === c[4][1] + 1 && c[6][0] === c[4][0] + 2
          && c[8][1] === c[6][1] && c[8][0] === c[6][0]
          && c[10][1] === c[6][1] + 1
        console.info(ok ? "IDLE OK" : "IDLE FAIL " + JSON.stringify(win.log))
        Qt.exit(ok ? 0 : 1)
      }
    }
  }
}
