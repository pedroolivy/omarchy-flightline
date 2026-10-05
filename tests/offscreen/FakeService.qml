import QtQuick
import "../../Model.js" as Model

// Test stand-in for Service.qml: the part of its API that GlobeView reads,
// fed from one flightline-feed output directory (traffic.ppm, meta.json and
// the helper's summary line saved as summary.json, see globeview.sh).
//
// The fixture's epoch is moved to "now", so observation ages are the ones
// the feed reported and dead reckoning behaves as it would live. Like
// Service.qml, meta.json is parsed only when something asks for it, at most
// once per revision, so the first-hover cost shows up in tests as it does
// live; bump() publishes the same fixture again as a new revision.
// Reading files needs QML_XHR_ALLOW_FILE_READ=1.
QtObject {
  id: root

  property string dir: ""
  property string mode: "region"
  readonly property string trafficPath: dir ? "file://" + dir + "/traffic.ppm" : ""
  property int trafficRev: 0
  property int trafficCount: 0
  property double epochMs: 0
  property real maxGs: 0
  property var summary: null
  property var lastQuery: null
  property var emergencies: []
  property var metaData: null             // parsed meta of trafficRev (meta() fills it)
  property string metaText: ""
  property int metaRev: -1

  function meta() {
    if (metaRev === trafficRev) return metaData
    metaRev = trafficRev
    var m = Model.parseMeta(metaText)
    if (m) {
      m.rev = trafficRev
      m.epochMs = epochMs
    }
    metaData = m
    return m
  }
  function aircraftAt(i) { return Model.metaRow(meta(), i) }

  // The same traffic as a new revision, observed again just now.
  function bump() {
    epochMs = Date.now() - 300000
    trafficRev++
  }

  function read(name, done) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState === XMLHttpRequest.DONE) done(xhr.responseText)
    }
    xhr.open("GET", "file://" + dir + "/" + name)
    xhr.send()
  }

  onDirChanged: read("summary.json", function(text) {
    var s = Model.parseSummary(text)
    read("meta.json", function(metaText) {
      if (!s || !s.ok || !Model.parseMeta(metaText)) {
        console.warn("FakeService: unreadable fixture in " + dir)
        return
      }
      root.metaText = metaText
      root.summary = s
      root.epochMs = Date.now() - 300000
      root.maxGs = s.maxGs
      root.trafficCount = s.n
      root.lastQuery = s.query
      root.emergencies = s.emergencies
      root.trafficRev = s.rev
    })
  })
}
