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

///|
async test "a poll checks after a check whose read failed, though nothing changed since" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  let checks = []
  @async.with_task_group(group => {
    let watch = @watch.Watch(dir, stamp=stamp => stamp.note("the same"))
    group.spawn_bg(no_wait=true, () => {
      defer watch.close()
      watch.run(check => {
        checks.push(@debug.to_string(check))
        // The first read fails, the next one works.
        if checks.length() == 1 {
          watch.forget()
        }
      })
    })
    @fs.write_file("\{dir}/other.json", "{}")
    @async.sleep(11_000)
  })
  inspect(
    checks.join("\n"),
    content=(
      #|Changed
      #|Poll
    ),
  )
}

///|
async test "a file time ahead of the clock is told once, and again only after a stamp noted none" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.mkdir("\{dir}/watched")
  let path = "\{dir}/users.json"
  @fs.write_file(path, "{}")
  let set_ahead = async fn() {
    let ahead = @async.now() / 1000 + 86_400
    let status = @process.run("touch", ["-m", "-d", "@\{ahead}", path])
    guard status == 0 else { fail("touch exited with \{status}") }
  }
  set_ahead()
  let out = []
  @async.with_task_group(group => {
    let watch = @watch.Watch("\{dir}/watched", stamp=stamp => {
      stamp.note_file(path)
    })
    group.spawn_bg(no_wait=true, () => {
      defer watch.close()
      watch.run(check => out.push(@debug.to_string(check)), on_ahead=(file, _) => {
        out.push("ahead: \{file == path}")
      })
    })
    // Each step ends with an event, for a check.
    let steps : Array[async () -> Unit] = [
      () => (),
      () => @fs.write_file(path, "{}"),
      () => set_ahead(),
    ]
    for step in steps {
      step()
      @fs.write_file("\{dir}/watched/event", "")
      @async.sleep(500)
    }
  })
  inspect(
    out.join("\n"),
    content=(
      #|ahead: true
      #|Changed
      #|Changed
      #|Changed
      #|ahead: true
    ),
  )
}
