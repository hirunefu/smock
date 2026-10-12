///|
/// A logger whose lines are collected in memory and whose clock is fixed at
/// 2026-10-12T14:30:05.123Z.
fn capture() -> (@log.Logger, Array[String]) {
  let lines = []
  let logger = @log.Logger(write_line=line => lines.push(line), now=() => {
    1_791_815_405_123L
  })
  (logger, lines)
}

///|
test "an entry is one JSON object with the time, the level and the message" {
  let (logger, lines) = capture()
  logger.info("listening")
  inspect(
    lines.join("\n"),
    content=(
      #|{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"listening"}
    ),
  )
}

///|
test "structured fields follow the message, in the order given" {
  let (logger, lines) = capture()
  logger.info("listening", fields={
    "port": 8080,
    "tls": false,
    "hosts": ["a.example", "b.example"],
    "limits": { "headers": 100 },
  })
  inspect(
    lines.join("\n"),
    content=(
      #|{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"listening","port":8080,"tls":false,"hosts":["a.example","b.example"],"limits":{"headers":100}}
    ),
  )
}

///|
test "each entry names its level and takes one line" {
  let (logger, lines) = capture()
  logger.info("reloaded")
  logger.warn("certificate expires soon", fields={ "days": 3 })
  logger.error("reload failed", fields={ "errors": 2 })
  inspect(
    lines.join("\n"),
    content=(
      #|{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"reloaded"}
      #|{"time":"2026-10-12T14:30:05.123Z","level":"warn","msg":"certificate expires soon","days":3}
      #|{"time":"2026-10-12T14:30:05.123Z","level":"error","msg":"reload failed","errors":2}
    ),
  )
}

///|
test "newlines and quotes in messages and fields stay inside one line" {
  let (logger, lines) = capture()
  logger.error("invalid definitions:\n  \"a.json\"", fields={
    "file": "dir\twith\ttabs/b\"\n.json",
  })
  inspect(lines.length(), content="1")
  inspect(
    lines[0],
    content=(
      #|{"time":"2026-10-12T14:30:05.123Z","level":"error","msg":"invalid definitions:\n  \"a.json\"","file":"dir\twith\ttabs/b\"\n.json"}
    ),
  )
}

///|
test "a field named like time, level or msg does not replace them" {
  let (logger, lines) = capture()
  logger.info("reloaded", fields={
    "msg": "from a field",
    "time": 5,
    "level": "debug",
    "files": 3,
  })
  inspect(
    lines.join("\n"),
    content=(
      #|{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"reloaded","fields.msg":"from a field","fields.time":5,"fields.level":"debug","files":3}
    ),
  )
}

///|
/// The clock steps through: the Unix epoch; one millisecond before it; the
/// last millisecond of 2024-02-29 and the first of 2024-03-01; 2000-02-29, a
/// leap day in a year divisible by 400; and 2100-03-01, after a February with
/// 28 days.
test "the time is UTC with milliseconds, across the calendar" {
  let times = [
    0L, -1L, 1_709_251_199_999L, 1_709_251_200_000L, 951_782_400_000L, 4_107_542_400_000L,
  ]
  let lines = []
  let mut next = 0
  let logger = @log.Logger(write_line=line => lines.push(line), now=() => {
    next += 1
    times[next - 1]
  })
  for _ in times {
    logger.info("tick")
  }
  inspect(
    lines.join("\n"),
    content=(
      #|{"time":"1970-01-01T00:00:00.000Z","level":"info","msg":"tick"}
      #|{"time":"1969-12-31T23:59:59.999Z","level":"info","msg":"tick"}
      #|{"time":"2024-02-29T23:59:59.999Z","level":"info","msg":"tick"}
      #|{"time":"2024-03-01T00:00:00.000Z","level":"info","msg":"tick"}
      #|{"time":"2000-02-29T00:00:00.000Z","level":"info","msg":"tick"}
      #|{"time":"2100-03-01T00:00:00.000Z","level":"info","msg":"tick"}
    ),
  )
}
