import QtQuick

// Offscreen test driver: once `ready`, for each name in `names` emits
// prepare(i), waits a moment for the scene to settle, grabs `target` into
// <out dir>/<name> and finally quits. The out dir is the first argument after
// "--" (tests/offscreen/run.sh passes it).
Timer {
  id: root

  property Item target
  property bool ready: true
  property var names: []
  property int index: -1
  readonly property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)
  readonly property string outDir: args.length > 0 ? args[0] : "."

  signal prepare(int index)

  // {url, count, epochMs} of a fixture packed by run.sh, or null
  function fixture(name) {
    for (var i = 1; i < args.length; i++) {
      var f = args[i].split(":")
      if (f[0] === name)
        return { url: "file://" + outDir + "/" + name + ".ppm", count: Number(f[1]), epochMs: Number(f[2]) }
    }
    return null
  }

  interval: 400
  onReadyChanged: if (ready && index < 0) next()
  Component.onCompleted: if (ready && index < 0) next()

  function next() {
    index++
    if (index >= names.length) {
      Qt.quit()
      return
    }
    prepare(index)
    start()
  }

  onTriggered: target.grabToImage(function (result) {
    result.saveToFile(root.outDir + "/" + root.names[root.index])
    console.info("saved", root.names[root.index])
    root.next()
  })
}
