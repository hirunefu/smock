///|
/// A logger in the format `format` whose lines are collected in memory and
/// whose clock is fixed at 2026-10-22T09:00:00.000Z, the time of the spec's
/// example of an entry in both formats.
fn capture_in(format : @log.Format) -> (@log.Logger, Array[String]) {
  let lines = []
  let logger = @log.Logger(format~, write_line=line => lines.push(line), now=() => {
    1_792_659_600_000L
  })
  (logger, lines)
}

///|
test "the same entry in both formats: json keeps its keys in order, mockoon sorts them with app, level, message and timestamp" {
  let fields : Map[String, Json] = {
    "result": "swapped",
    "oldDigest": "3f1c0a9b2e7d",
    "newDigest": "8a41d0c2f5e3",
    "scenarioStatesReset": 0,
    "dataBucketsReset": 1,
  }
  let out = []
  for format in [@log.Format::Json, Mockoon] {
    let (logger, lines) = capture_in(format)
    logger.info("definitions reloaded", fields~)
    out.push(lines.join("\n"))
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"time":"2026-10-22T09:00:00.000Z","level":"info","msg":"definitions reloaded","result":"swapped","oldDigest":"3f1c0a9b2e7d","newDigest":"8a41d0c2f5e3","scenarioStatesReset":0,"dataBucketsReset":1}
      #|{"app":"smock","dataBucketsReset":1,"level":"info","message":"definitions reloaded","newDigest":"8a41d0c2f5e3","oldDigest":"3f1c0a9b2e7d","result":"swapped","scenarioStatesReset":0,"timestamp":"2026-10-22T09:00:00.000Z"}
    ),
  )
}
