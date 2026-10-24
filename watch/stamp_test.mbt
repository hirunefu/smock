// What a poll compares before it reads anything: a stamp notes the names a
// check would list and the times of the files it would read, and a poll
// reads only when the stamp may have changed since the last one. Real files
// give the times; each stamp is given the time it is taken at, so that a
// test can say how long after a change it was taken.

///|
/// A stamp taken at `at` that notes `names` and the file at `path`.
async fn stamp_of(
  path : String,
  at~ : Int64,
  names~ : String = "users.json",
) -> @watch.Stamp {
  let stamp = @watch.Stamp(now=at)
  stamp.note(names)
  stamp.note_file(path)
  stamp
}

///|
/// When the file at `path` last changed, in milliseconds since the epoch.
async fn changed_at(path : String) -> Int64 {
  let (seconds, nanoseconds) = @fs.ctime(path)
  seconds * 1000 + (nanoseconds / 1_000_000).to_int64()
}

///|
async test "a poll trusts the last stamp only when it was taken at least 2 s after the newest change it notes" {
  let dir = @fs.tmpdir(prefix="smock-stamp-")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/users.json"
  @fs.write_file(path, "{}")
  let changed = changed_at(path)
  let poll = stamp_of(path, at=changed + 12_000)
  inspect(
    (
      $|last taken 1.9 s after the change: unchanged \{poll.unchanged_since(stamp_of(path, at=changed + 1900))}
      $|last taken 2.1 s after the change: unchanged \{poll.unchanged_since(stamp_of(path, at=changed + 2100))}
    ),
    content=(
      #|last taken 1.9 s after the change: unchanged false
      #|last taken 2.1 s after the change: unchanged true
    ),
  )
}

///|
async test "a stamp changes when a noted file is written again, replaced through a symlink or removed, or other names are noted" {
  let dir = @fs.tmpdir(prefix="smock-stamp-")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/users.json"
  @fs.write_file("\{dir}/v1.json", "{}")
  @fs.write_file("\{dir}/v2.json", "{}")
  @fs.symlink(target="v1.json", path)
  // Far enough after the files were written to be trusted.
  let at = changed_at("\{dir}/v2.json") + 60_000
  let last = stamp_of(path, at~)
  let out = [
    "nothing changed: unchanged \{stamp_of(path, at~).unchanged_since(last)}",
    "other names noted: unchanged \{stamp_of(path, at~, names="orders.json").unchanged_since(last)}",
  ]
  // Later than the coarsest clock tick, so that each change gets a time of
  // its own.
  let changes : Array[(String, async () -> Unit)] = [
    ("written again with the same bytes", () => @fs.write_file(path, "{}")),
    (
      "replaced through a symlink",
      () => {
        @fs.symlink(target="v2.json", "\{dir}/next")
        @fs.rename("\{dir}/next", path)
      },
    ),
    ("removed", () => @fs.remove("\{dir}/v2.json")),
  ]
  let mut last = last
  for change in changes {
    let (name, make) = change
    @async.sleep(20)
    make()
    let next = stamp_of(path, at~)
    out.push("\{name}: unchanged \{next.unchanged_since(last)}")
    last = next
  }
  inspect(
    out.join("\n"),
    content=(
      #|nothing changed: unchanged true
      #|other names noted: unchanged false
      #|written again with the same bytes: unchanged false
      #|replaced through a symlink: unchanged false
      #|removed: unchanged false
    ),
  )
}

///|
/// Sets the modification time of the file at `path` to `seconds` since the
/// epoch, which also sets its change time to now: moonbitlang/async has no
/// call for it.
async fn set_modified(path : String, seconds~ : Int64) -> Unit {
  let status = @process.run("touch", ["-m", "-d", "@\{seconds}", path])
  guard status == 0 else { fail("touch exited with \{status}") }
}

///|
async test "a modification time ahead of the clock does not keep a stamp from being trusted, and is told" {
  let dir = @fs.tmpdir(prefix="smock-stamp-")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/users.json"
  @fs.write_file(path, "{}")
  // A day ahead, as from a host whose clock ran ahead.
  let ahead = @async.now() / 1000 + 86_400
  set_modified(path, seconds=ahead)
  let changed = changed_at(path)
  let last = stamp_of(path, at=changed + 2100)
  let poll = stamp_of(path, at=changed + 12_000)
  // Later than the coarsest clock tick, so that the write gets a time of
  // its own.
  @async.sleep(20)
  @fs.write_file(path, "{}")
  let written = stamp_of(path, at=changed + 12_000)
  inspect(
    (
      $|nothing changed: unchanged \{poll.unchanged_since(last)}
      $|written again: unchanged \{written.unchanged_since(poll)}
      $|ahead of the clock: \{last.ahead() == Some((path, ahead * 1000))}
      $|after the write, ahead of the clock: \{written.ahead() is Some(_)}
    ),
    content=(
      #|nothing changed: unchanged true
      #|written again: unchanged false
      #|ahead of the clock: true
      #|after the write, ahead of the clock: false
    ),
  )
}

///|
async test "a stamp notes where a file really is, so that a symlink pointed at another file with the very same times shows" {
  let dir = @fs.tmpdir(prefix="smock-stamp-")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/users.json"
  @fs.mkdir("\{dir}/a")
  @fs.mkdir("\{dir}/b")
  @fs.write_file("\{dir}/a/users.json", "{}")
  // A hard link: another name for the same file, so the very same times,
  // as two files written within one clock tick can have.
  let status = @process.run("ln", ["\{dir}/a/users.json", "\{dir}/b/users.json"])
  guard status == 0 else { fail("ln exited with \{status}") }
  @fs.symlink(target="a/users.json", path)
  let at = changed_at("\{dir}/a/users.json") + 60_000
  let last = stamp_of(path, at~)
  @fs.symlink(target="b/users.json", "\{dir}/next")
  @fs.rename("\{dir}/next", path)
  inspect(
    "pointed at b: unchanged \{stamp_of(path, at~).unchanged_since(last)}",
    content="pointed at b: unchanged false",
  )
}
