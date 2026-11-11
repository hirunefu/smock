// Polls of a watched directory, every second: a poll takes a stamp of what
// the caller reads and checks only when it may have changed since the last
// stamp, which the watch first takes when it starts. Some stamps here note
// files outside the watched directory, which only a stamp can see change.

///|
async test "a poll checks only when the stamp may have changed since the last one, which the watch takes when it starts: Changed when it notes something else, then Poll while that stamp is too new to be trusted" {
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
    // Half a second after the watches took their first stamp. The poll 1 s
    // after they started notes the new times; the stamps of the next two
    // polls note the same, but each compares with one taken less than 2 s
    // after the change; the poll 4 s after the start compares with one
    // that is trusted.
    @async.sleep(500)
    @fs.write_file("\{dir}/changed.json", "{\"changed\": true}")
    @async.sleep(4000)
  })
  inspect(
    checks.join("\n"),
    content=(
      #|changed: Changed
      #|changed: Poll
      #|changed: Poll
    ),
  )
}

///|
async test "each change of what the stamp notes is checked by the next poll, within a second" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  // What the caller reads, as its stamp notes it: no file times, so each
  // stamp is trusted at once.
  let state = Ref("A")
  let checks = []
  @async.with_task_group(group => {
    let started = @async.now()
    let watch = @watch.Watch(dir, stamp=stamp => stamp.note(state.val))
    group.spawn_bg(no_wait=true, () => {
      defer watch.close()
      watch.run(check => {
        let after = (@async.now() - started + 500) / 1000
        checks.push("\{@debug.to_string(check)} after about \{after} s")
      })
    })
    // A change, then a change back, each half a second before a poll. A
    // file written in the directory changes nothing the stamp notes.
    @async.sleep(500)
    state.val = "B"
    @async.sleep(1000)
    state.val = "A"
    @async.sleep(1000)
    @fs.write_file("\{dir}/other.json", "{}")
    @async.sleep(1000)
  })
  inspect(
    checks.join("\n"),
    content=(
      #|Changed after about 1 s
      #|Changed after about 2 s
    ),
  )
}

///|
async test "a poll checks after a check whose read failed, though nothing changed since" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  let state = Ref("A")
  let checks = []
  @async.with_task_group(group => {
    let watch = @watch.Watch(dir, stamp=stamp => stamp.note(state.val))
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
    state.val = "B"
    @async.sleep(3500)
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
    // The first poll, 1 s after the start, checks with the same time
    // ahead, since the stamp taken at the start is too new to be trusted.
    // Each step after it comes half a second before a poll.
    let steps : Array[async () -> Unit] = [
      () => @fs.write_file(path, "{}"),
      () => set_ahead(),
    ]
    @async.sleep(1500)
    for step in steps {
      step()
      @async.sleep(1000)
    }
  })
  inspect(
    out.join("\n"),
    content=(
      #|ahead: true
      #|Poll
      #|Changed
      #|Changed
      #|ahead: true
    ),
  )
}
