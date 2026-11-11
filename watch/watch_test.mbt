// Polls of a watch, every second: a poll takes a stamp of what the caller
// reads and checks only when it may have changed since the last stamp,
// which the watch first takes when it starts. A change is checked once it
// has settled: when a stamp 250 ms after the one before it notes the same.
// When the stamps come is for the Schedule tests to check.

///|
async test "a poll checks only when the stamp may have changed since the last one, which the watch takes when it starts: Changed once the change settles, then Unsure while the stamp kept is too new to be trusted" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  for name in ["same", "changed"] {
    @fs.write_file("\{dir}/\{name}.json", "{}")
  }
  // Older than the 2 s a stamp needs to be trusted.
  @async.sleep(2500)
  let checks = []
  @async.with_task_group(group => {
    for name in ["same", "changed"] {
      let watch = @watch.Watch(stamp=stamp => {
        stamp.note_file("\{dir}/\{name}.json")
      })
      group.spawn_bg(no_wait=true, () => {
        watch.run(check => checks.push("\{name}: \{@debug.to_string(check)}"))
      })
    }
    // 0.6 s after the watches took their first stamp. The poll 1 s after
    // they started notes the new times, and the stamp 250 ms after it the
    // same, so the watch checks and keeps that stamp. It was taken less
    // than 2 s after the change, and so was the one the next poll keeps:
    // the next two polls note the same, but each compares with a stamp too
    // new to be trusted; the poll after them, with one that is trusted.
    @async.sleep(600)
    @fs.write_file("\{dir}/changed.json", "{\"changed\": true}")
    @async.sleep(3900)
  })
  inspect(
    checks.join("\n"),
    content=(
      #|changed: Changed
      #|changed: Unsure
      #|changed: Unsure
    ),
  )
}

///|
/// Runs a watch whose stamps note `notes`, one after the other, the first
/// when the watch starts, until it takes one more stamp, which notes the
/// last again. Lists the note of each stamp in `notes` and each check, in
/// the order they came. `on_check` is called with the watch at each check.
/// What the stamps note has no file times, so each stamp is trusted at
/// once.
async fn scripted(
  notes : Array[String],
  on_check~ : (@watch.Watch) -> Unit = _ => (),
) -> String {
  let out = []
  let taken = Ref(0)
  @async.with_task_group(group => {
    let watch = @watch.Watch(stamp=stamp => {
      let i = taken.val
      taken.val += 1
      let note = if i < notes.length() {
        out.push(notes[i])
        notes[i]
      } else {
        notes[notes.length() - 1]
      }
      stamp.note(note)
    })
    group.spawn_bg(no_wait=true, () => {
      watch.run(check => {
        out.push(@debug.to_string(check))
        on_check(watch)
      })
    })
    let done = @async.with_timeout_opt(10_000, () => {
      while taken.val <= notes.length() {
        @async.sleep(20)
      }
    })
    guard done is Some(_) else {
      fail("too few stamps in time: \{out.join(" ")}")
    }
  })
  out.join(" ")
}

///|
async test "a change is checked once, when a stamp notes the same as the stamp before it, and the watch keeps that stamp" {
  // The first poll notes B, the stamps after it C, then C again: a check.
  // The next poll compares with the C kept, and checks nothing.
  inspect(scripted(["A", "B", "C", "C", "C"]), content="A B C C Changed C")
}

///|
async test "a change that settles back to what the stamp before it noted is checked all the same: something was written" {
  inspect(scripted(["A", "B", "A", "A"]), content="A B A A Changed")
}

///|
async test "after a check whose read failed, the next poll checks at once, though nothing changed since" {
  let failed = Ref(false)
  inspect(
    scripted(["A", "B", "B", "B"], on_check=watch => {
      // The first read fails, the next one works.
      if !failed.val {
        failed.val = true
        watch.forget()
      }
    }),
    content="A B B Changed B Unsure",
  )
}

///|
async test "a file time ahead of the clock is told once, and again only after a stamp noted none" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/users.json"
  @fs.write_file(path, "{}")
  let set_ahead = async fn() {
    let ahead = @async.now() / 1000 + 86_400
    let status = @process.run("touch", ["-m", "-d", "@\{ahead}", path])
    guard status == 0 else { fail("touch exited with \{status}") }
  }
  set_ahead()
  let out = []
  let checks = Ref(0)
  @async.with_task_group(group => {
    let watch = @watch.Watch(stamp=stamp => stamp.note_file(path))
    group.spawn_bg(no_wait=true, () => {
      watch.run(
        check => {
          out.push(@debug.to_string(check))
          checks.val += 1
        },
        on_ahead=(file, _) => out.push("ahead: \{file == path}"),
      )
    })
    // The first poll checks with the same time ahead, since the stamp
    // taken at the start is too new to be trusted. Each step comes after
    // the check before it.
    let steps : Array[async () -> Unit] = [
      () => @fs.write_file(path, "{}"),
      () => set_ahead(),
      () => (),
    ]
    for i, step in steps {
      let checked = @async.with_timeout_opt(5000, () => {
        while checks.val <= i {
          @async.sleep(20)
        }
      })
      guard checked is Some(_) else {
        fail("too few checks in time: \{out.join(" ")}")
      }
      step()
    }
  })
  inspect(
    out.join("\n"),
    content=(
      #|ahead: true
      #|Unsure
      #|Changed
      #|ahead: true
      #|Changed
    ),
  )
}
