///|
let sample : @buildinfo.BuildInfo = {
  version: "1.2.3",
  commit: "0123456789ab",
  toolchain: "moonc v0.10.17+d971670cd",
}

///|
test "the version line names the version, the commit and the toolchain" {
  inspect(
    sample.version_line(),
    content="smock 1.2.3 (commit 0123456789ab, moonc v0.10.17+d971670cd)",
  )
}

///|
test "the startup entry carries the version, the commit and the toolchain" {
  let lines = []
  let logger = @log.Logger(write_line=line => lines.push(line), now=() => {
    1_791_815_405_123L
  })
  sample.log_startup(logger)
  inspect(
    lines.join("\n"),
    content=(
      #|{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"smock starting","version":"1.2.3","commit":"0123456789ab","toolchain":"moonc v0.10.17+d971670cd"}
    ),
  )
}

///|
test "the startup entry carries further fields after the build" {
  let lines = []
  let logger = @log.Logger(write_line=line => lines.push(line), now=() => {
    1_791_815_405_123L
  })
  sample.log_startup(logger, fields={ "adminAuth": "off" })
  inspect(
    lines.join("\n"),
    content=(
      #|{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"smock starting","version":"1.2.3","commit":"0123456789ab","toolchain":"moonc v0.10.17+d971670cd","adminAuth":"off"}
    ),
  )
}
