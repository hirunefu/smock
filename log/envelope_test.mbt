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

///|
/// A logger in the `Mockoon` format whose lines are collected in memory and
/// whose clock is fixed at `at`.
fn capture_at(at : Int64) -> (@log.Logger, Array[String]) {
  let lines = []
  let logger = @log.Logger(
    format=Mockoon,
    write_line=line => lines.push(line),
    now=() => at,
  )
  (logger, lines)
}

///|
test "keys are sorted at every depth, in objects inside arrays too, and arrays keep their order" {
  // 2026-10-31T09:00:07.000Z, the time of the spec's example.
  let (logger, lines) = capture_at(1_793_437_207_000L)
  logger.error("definitions reload failed", fields={
    "result": "failed",
    "digest": "3f1c0a9b2e7d",
    "errors": [
      {
        "file": "users.yaml",
        "pointer": "/stubs/0/respons",
        "message": "is not a known field",
      },
    ],
  })
  logger.error("definitions reload failed", fields={
    "errors": [
      { "file": "z.yaml", "pointer": "/stubs/1", "message": "first" },
      {
        "file": "a.yaml",
        "where": {
          "line": 3,
          "column": 1,
          "path": ["stubs", 0, { "b": 1, "a": 2 }],
        },
      },
    ],
  })
  inspect(
    lines.join("\n"),
    content=(
      #|{"app":"smock","digest":"3f1c0a9b2e7d","errors":[{"file":"users.yaml","message":"is not a known field","pointer":"/stubs/0/respons"}],"level":"error","message":"definitions reload failed","result":"failed","timestamp":"2026-10-31T09:00:07.000Z"}
      #|{"app":"smock","errors":[{"file":"z.yaml","message":"first","pointer":"/stubs/1"},{"file":"a.yaml","where":{"column":1,"line":3,"path":["stubs",0,{"a":2,"b":1}]}}],"level":"error","message":"definitions reload failed","timestamp":"2026-10-31T09:00:07.000Z"}
    ),
  )
}

///|
/// UTF-16 code-unit order puts upper case before lower case, a key before
/// the longer keys it starts, and an emoji, whose first code unit is a
/// high surrogate (U+D83D), before U+FF01, which code-point order would put
/// first.
test "keys sort in UTF-16 code-unit order: upper case first, then lower case, a prefix before its longer keys" {
  let (logger, lines) = capture_at(1_793_437_207_000L)
  logger.warn("sorted", fields={
    "routeUUID": "create-order",
    "routePath": "/orders",
    "apple": 2,
    "Zebra": 1,
    "Apple": 3,
    "\u{ff01}": "fullwidth",
    "\u{1f600}": "emoji",
    "z": true,
  })
  inspect(
    lines.join("\n"),
    content=(
      #|{"Apple":3,"Zebra":1,"app":"smock","apple":2,"level":"warn","message":"sorted","routePath":"/orders","routeUUID":"create-order","timestamp":"2026-10-31T09:00:07.000Z","z":true,"😀":"emoji","！":"fullwidth"}
    ),
  )
}

///|
test "a field named app, level, message or timestamp is written as fields.<name>, and time and msg as they are" {
  let (logger, lines) = capture_at(1_793_437_207_000L)
  logger.info("reloaded", fields={
    "app": "mockoon-server",
    "level": "debug",
    "message": "from a field",
    "timestamp": 5,
    "time": 1,
    "msg": "kept",
  })
  inspect(
    lines.join("\n"),
    content=(
      #|{"app":"smock","fields.app":"mockoon-server","fields.level":"debug","fields.message":"from a field","fields.timestamp":5,"level":"info","message":"reloaded","msg":"kept","time":1,"timestamp":"2026-10-31T09:00:07.000Z"}
    ),
  )
}

///|
/// 9007199254740993 is 2^53 + 1, which a Double cannot hold: the number
/// keeps the digits it was given.
test "numbers are written as the json format writes them, so a large seed keeps every digit" {
  let seed = 9_007_199_254_740_993UL
  let fields : Map[String, Json] = {
    "seed": Json::number(seed.to_double(), repr=seed.to_string()),
    "ratio": 0.25,
    "offset": -3,
    "nothing": Json::null(),
  }
  let out = []
  for format in [@log.Format::Json, Mockoon] {
    let (logger, lines) = capture_in(format)
    logger.info("random seed", fields~)
    out.push(lines.join("\n"))
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"time":"2026-10-22T09:00:00.000Z","level":"info","msg":"random seed","seed":9007199254740993,"ratio":0.25,"offset":-3,"nothing":null}
      #|{"app":"smock","level":"info","message":"random seed","nothing":null,"offset":-3,"ratio":0.25,"seed":9007199254740993,"timestamp":"2026-10-22T09:00:00.000Z"}
    ),
  )
}

///|
test "strings in the envelope are escaped as JSON.stringify escapes them, keys included, with / as it is" {
  let (logger, lines) = capture_at(1_793_437_207_000L)
  logger.error("invalid definitions:\n  \"a.json\"", fields={
    "file": "dir\twith\\tabs/b\".json",
    "control\u{1}key": "\u{1f}\u{8}\u{c}\r",
    "mock": "ユーザー API",
  })
  inspect(
    lines.join("\n"),
    content=(
      #|{"app":"smock","control\u0001key":"\u001f\b\f\r","file":"dir\twith\\tabs/b\".json","level":"error","message":"invalid definitions:\n  \"a.json\"","mock":"ユーザー API","timestamp":"2026-10-31T09:00:07.000Z"}
    ),
  )
}
