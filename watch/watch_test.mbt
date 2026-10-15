// Polls of a watched directory: a poll takes a stamp of what the caller
// reads and checks only when it may have changed since the last stamp,
// which the watch first takes when it starts. The stamps here note files
// outside the watched directories, so that no event reports their changes
// and only a poll can find them. The test waits for the first poll, 10 s
// after the watches start.

///|
async test "a poll checks only when the stamp may have changed since the last one, which the watch takes when it starts" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  for name in ["same", "changed"] {
    @fs.mkdir("\{dir}/\{name}")
    @fs.write_file("\{dir}/\{name}.json", "{}")
  }
  // Older than the 2 s a stamp needs to be trusted.
  @async.sleep(2500)
  let checks = []
  @async.with_task_group(group => {
    for name in ["same", "changed"] {
      let watch = @watch.Watch("\{dir}/\{name}", stamp=stamp => {
        stamp.note_file("\{dir}/\{name}.json")
      })
      group.spawn_bg(no_wait=true, () => {
        defer watch.close()
        watch.run(check => checks.push("\{name}: \{@debug.to_string(check)}"))
      })
    }
    // After the watches took their first stamp.
    @fs.write_file("\{dir}/changed.json", "{\"changed\": true}")
    @async.sleep(10_500)
  })
  inspect(
    checks.join("\n"),
    content=(
      #|changed: Poll
    ),
  )
}

///|
async test "a poll compares its stamp with the one taken before the last check, even a check after events" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  // What the caller reads, as its stamp notes it: no file times, so each
  // stamp is trusted at once.
  let state = Ref("A")
  let checks = []
  @async.with_task_group(group => {
    let watch = @watch.Watch(dir, stamp=stamp => stamp.note(state.val))
    group.spawn_bg(no_wait=true, () => {
      defer watch.close()
      watch.run(check => checks.push(@debug.to_string(check)))
    })
    // A change that no event reports, then one in the directory that an
    // event does: the check after it reads B.
    state.val = "B"
    @fs.write_file("\{dir}/other.json", "{}")
    @async.sleep(1000)
    // Back to A, again with no event: the next poll, 10 s after that check,
    // finds that the files differ from those read last.
    state.val = "A"
    @async.sleep(10_000)
  })
  inspect(
    checks.join("\n"),
    content=(
      #|Changed
      #|Poll
    ),
  )
}
