///|
async test "stdout lines: while stdout stalls, smock's own lines beyond 1,024 are dropped and counted, memory stays flat, and a request's line still waits for its own write" {
  @async.with_task_group(group => {
    // A stdout whose reader has stopped reading, until `stalled` is unset.
    let stalled = Ref(true)
    let resumed = @cond_var.Cond()
    // Each write, as one line and its newline, or as it came when it is
    // not one.
    let written : Array[String] = []
    let stdout = StdoutLines::writing_to(async fn(bytes) noraise {
      while stalled.val {
        resumed.wait()
      }
      let text = @utf8.decode_lossy(bytes)
      written.push(
        match text.strip_suffix("\n") {
          Some(line) if !line.contains("\n") => line.to_owned()
          _ => "not one line: \{text.escape()}"
        },
      )
    })
    group.spawn_bg(no_wait=true, () => stdout.run())
    // The writer takes the first line, and waits on it.
    stdout.push("first")
    @async.pause()
    let before = resident_kib()
    // Kept, these would take more than 20 MiB.
    for i in 0..<60_000 {
      stdout.push(
        "an entry of smock's own, number \{i}, as long as most are: " +
        "x".repeat(120),
      )
    }
    let grown = resident_kib() - before
    // A request's line is never dropped: its task waits for it.
    let request = group.spawn(() => stdout.write("Transaction recorded"))
    @async.pause()
    stdout.push("after the request")
    let waiting = request.try_wait() is None
    stalled.val = false
    resumed.broadcast()
    request.wait()
    inspect(
      (
        $|grew by less than 4 MiB: \{grown < 4096}
        $|dropped: \{stdout.dropped}
        $|the request waited while stdout stalled: \{waiting}
        $|written: \{written.length()} lines, \{written.iter().filter(line => line.has_prefix("not one line")).count()} not one line each
        $|\{written[0]}
        $|\{written[1].view(end_offset=33)}…
        $|\{written[1024].view(end_offset=36)}…
        $|\{written[written.length() - 1]}
      ),
      content=(
        #|grew by less than 4 MiB: true
        #|dropped: 58977
        #|the request waited while stdout stalled: true
        #|written: 1026 lines, 0 not one line each
        #|first
        #|an entry of smock's own, number 0…
        #|an entry of smock's own, number 1023…
        #|Transaction recorded
      ),
    )
  })
}
