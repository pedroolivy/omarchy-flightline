import QtQuick
import QtQuick.Window
import "../.."

// (d) The "Look up" lens over a real saved world response (WORLD_JSON, turned
// into a meta.json by lookup.sh): JFK just after sunset with sunlit aircraft,
// London at night, Alice Springs where traffic is sparse and the data stops at
// 100 NM, a small card, and the two empty states. A stand-in service reads
// meta.json from disk the way Service.meta() does.
Window {
  id: win
  width: 640
  height: 600
  visible: true
  color: "#1a1b26"

  readonly property string dataDir: shots.outDir + "/lookup-data"

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

  Item {
    id: scene
    anchors.fill: parent

    Rectangle {
      anchors.fill: parent
      color: win.color
    }
    LookUp {
      id: look
      anchors.fill: parent
      service: mock
      fontFamily: "monospace"
      fontPx: 12
      units: "metric"
      fixedNowMs: win.metaData.epochMs + 305000
      home: ({ lat: 40.64, lon: -73.78, name: "JFK" })
    }
  }

  function selectNth(n) {
    look.rebuild()
    var rows = look.scan ? look.scan.sky : []
    look.selectedIndex = rows.length > n ? rows[n].i : -1
    console.info("selected", look.selectedIndex, JSON.stringify(look.selectedRow ? { name: look.selectedRow.name, el: Math.round(look.selectedRow.el), sunlit: look.selectedRow.sunlit } : null))
  }

  function report(name) {
    var t0 = Date.now()
    look.rebuild()
    var ms = Date.now() - t0
    var c = look.scan ? look.scan.counts : null
    console.info("scan", name, "ms", ms, JSON.stringify(c), "passes", look.passes.length, "beyond",
      JSON.stringify(look.beyond.map(function (b) { return b.name + " " + Math.round(b.km) + "km" })))
  }

  Shots {
    id: shots
    target: scene
    names: ["d-jfk-sunlit.png", "d-london-night.png", "d-outback-sparse.png", "d-small.png", "d-no-home.png", "d-no-data.png"]
    onPrepare: function (i) {
      if (i === 0) {
        win.report("jfk")
        win.selectNth(3)
      }
      if (i === 1) {
        look.selectedIndex = -1
        look.home = { lat: 51.47, lon: -0.45, name: "LHR" }
        win.report("london")
        win.selectNth(5)
      }
      if (i === 2) {
        look.selectedIndex = -1
        look.home = { lat: -23.80, lon: 133.90, name: "ASP" }      // Alice Springs: a sparse sky
        mock.lastQuery = { lat: -23.80, lon: 133.90, radiusNm: 100 }
        win.report("outback")
        win.selectNth(0)
      }
      if (i === 3) {
        mock.lastQuery = null
        look.home = { lat: 40.64, lon: -73.78, name: "JFK" }
        look.selectedIndex = -1
        win.width = 420
        win.height = 380
        win.report("jfk-small")
      }
      if (i === 4) {
        win.width = 640
        win.height = 600
        look.home = null
        win.report("nohome")
      }
      if (i === 5) {
        look.home = { lat: 51.47, lon: -0.45 }
        look.service = null
        win.report("nodata")
      }
    }
  }
}
