// How a watch's polls glance before they stamp: every second a glance at
// what the last full stamp looked at, and the full stamp only when the
// glance may have missed a change, or 10 s after the full stamp before. The
// tests drive the watch on a clock of their own, which jumps to each
// deadline, and script its stamps and glances: they note one thing that
// changes, as it is when they look.

///|
/// One change of the thing a scripted watch looks at.
priv struct Change {
  /// When it is made: at `at`, before the looks at that time, or right
  /// after the first `after` of them.
  at : Int64
  after : Int32
  /// What a full stamp notes after it.
  value : String
  /// The change time it gives the thing, which a glance notes, or `None`
  /// when it keeps the one it had, as a symlink pointed at another file
  /// with the very same times does.
  changed : Int64?
}

///|
/// The thing a scripted watch looks at, the changes still to come, and
/// what each look noted, a line for each time it looked at.
priv struct World {
  /// What a full stamp notes of the thing now.
  mut value : String
  /// Its change time now, and the value whose change gave it, which is
  /// what a glance shows of it in `lines`.
  mut changed : Int64
  mut changed_by : String
  changes : Array[Change]
  /// How many of `changes` were made.
  mut made : Int32
  /// The time of the last look, and how many looks came at that time.
  mut looked_at : Int64
  mut looks : Int32
  lines : Array[String]
}

///|
/// A thing that holds `A`, last changed 10 s before the watch starts, at
/// 0, and will change as `changes` say, in that order.
fn World::World(changes : Array[Change]) -> World {
  {
    value: "A",
    changed: -10_000,
    changed_by: "A",
    changes,
    made: 0,
    looked_at: -1,
    looks: 0,
    lines: [],
  }
}

///|
/// Makes the changes due before a look at `now`, and counts the look.
fn World::look(self : World, now : Int64) -> Unit {
  if now != self.looked_at {
    self.looked_at = now
    self.looks = 0
  }
  while self.changes.get(self.made) is Some(change) &&
        (change.at < now || (change.at == now && change.after <= self.looks)) {
    self.value = change.value
    if change.changed is Some(changed) {
      self.changed = changed
      self.changed_by = change.value
    }
    self.made += 1
  }
  self.looks += 1
}

///|
/// Adds `text` to the line of the time looked at last.
fn World::show(self : World, text : String) -> Unit {
  let last = self.lines.length() - 1
  self.lines[last] = "\{self.lines[last]} \{text}"
}

///|
/// A full stamp: notes the thing's value, with its change time as the
/// newest file time.
fn World::stamp(self : World, stamp : Stamp) -> Unit {
  self.look(stamp.taken_at)
  stamp.note(self.value)
  stamp.newest = self.changed
  self.show("stamp \{self.value}")
}

///|
/// A glance at `now`: notes the thing's change time.
fn World::glance(self : World, now : Int64) -> Stamp {
  self.look(now)
  let glance = Stamp(now~)
  glance.note(self.changed.to_string())
  glance.newest = self.changed
  self.show("glance \{self.changed_by}")
  glance
}

///|
/// Runs a watch of the thing, which starts at 0, the way `run` does, but on
/// a clock that jumps to each deadline, until the deadline is past `until`.
/// Calls `on_check` with the watch at each check. Lists what each stamp and
/// glance saw, a line for each time the watch looked: the time, what the
/// stamps were due for, what the glance and then the full stamp saw, and
/// the check, if any.
async fn World::watch(
  self : World,
  until~ : Int64,
  on_check~ : (Watch) -> Unit = _ => (),
) -> String {
  self.lines.push("0")
  let watch = Watch::start(
    stamp=stamp => self.stamp(stamp),
    glance=(_, now) => self.glance(now),
    now=0,
  )
  for now = watch.schedule.deadline()
      now <= until
      now = watch.schedule.deadline() {
    guard watch.schedule.due(now) is Some(due) else { continue }
    self.lines.push("\{now} \{@debug.to_string(due)}")
    if watch.restamp(due, now) is Some(check) {
      self.lines[self.lines.length() - 1] += ": \{@debug.to_string(check)}"
      on_check(watch)
    }
  }
  self.lines.join("\n")
}

///|
/// A change made at `at`, with a change time of its own.
fn written(at : Int64, value : String) -> Change {
  { at, after: 0, value, changed: Some(at), }
}

///|
async test "without changes, each poll takes a glance, and the full stamp only at the first poll and 10 s after the full stamp before" {
  inspect(
    World([]).watch(until=12_000),
    content=(
      #|0 stamp A
      #|1000 Poll glance A stamp A
      #|2000 Poll glance A
      #|3000 Poll glance A
      #|4000 Poll glance A
      #|5000 Poll glance A
      #|6000 Poll glance A
      #|7000 Poll glance A
      #|8000 Poll glance A
      #|9000 Poll glance A
      #|10000 Poll glance A
      #|11000 Poll glance A stamp A
      #|12000 Poll glance A
    ),
  )
}

///|
async test "a change a glance sees takes the full stamp at the next poll, and polls take it until the glance before can be trusted, checking Unsure while the full stamp before cannot" {
  // The glances at 3 s and 4.25 s are taken less than 2 s after the change,
  // at 2.5 s, as is the full stamp at 4.25 s.
  inspect(
    World([written(2500, "B")]).watch(until=7250),
    content=(
      #|0 stamp A
      #|1000 Poll glance A stamp A
      #|2000 Poll glance A
      #|3000 Poll glance B stamp B
      #|3250 Quiet stamp B: Changed
      #|4250 Poll glance B stamp B: Unsure
      #|5250 Poll glance B stamp B: Unsure
      #|6250 Poll glance B
      #|7250 Poll glance B
    ),
  )
}

///|
async test "a change that only a full stamp sees, such as a symlink pointed at a file with the very same times, is seen 10 s after the full stamp before" {
  let change = { at: 2500, after: 0, value: "B", changed: None, }
  let lines = World([change]).watch(until=12_250)
  inspect(
    lines.split("\n").filter(line => line.contains("stamp")).join("\n"),
    content=(
      #|0 stamp A
      #|1000 Poll glance A stamp A
      #|11000 Poll glance A stamp B
      #|11250 Quiet stamp B: Changed
    ),
  )
}

///|
async test "a change made right after a poll's glance is seen by the full stamp after it, and one made right after the full stamp by the next poll's glance, though both point a symlink at a file written long before" {
  // The files' change times are old, so a glance that saw them would be
  // trusted at once: one taken after the full stamp, and kept for the next
  // poll in place of the one taken before it, would hide the change.
  let changes : Array[Change] = [
    { at: 1000, after: 1, value: "B", changed: Some(-5000), },
    { at: 2250, after: 2, value: "C", changed: Some(-4000), },
  ]
  inspect(
    World(changes).watch(until=4500),
    content=(
      #|0 stamp A
      #|1000 Poll glance A stamp B
      #|1250 Quiet stamp B: Changed
      #|2250 Poll glance B stamp B
      #|3250 Poll glance C stamp C
      #|3500 Quiet stamp C: Changed
      #|4500 Poll glance C
    ),
  )
}

///|
async test "a change that settles back to what the stamp before it noted is checked all the same: something was written" {
  inspect(
    World([written(500, "B"), written(1100, "A")]).watch(until=1500),
    content=(
      #|0 stamp A
      #|1000 Poll glance B stamp B
      #|1250 Quiet stamp A
      #|1500 Quiet stamp A: Changed
    ),
  )
}

///|
async test "after a check whose read failed, the next poll takes no glance and checks Unsure, and the poll after it compares its glance with the one before the check" {
  let failed = Ref(false)
  let change = { at: 500, after: 0, value: "B", changed: Some(-5000), }
  inspect(
    World([change]).watch(until=3250, on_check=watch => {
      // The first read fails, the next one works.
      if !failed.val {
        failed.val = true
        watch.forget()
      }
    }),
    content=(
      #|0 stamp A
      #|1000 Poll glance B stamp B
      #|1250 Quiet stamp B: Changed
      #|2250 Poll stamp B: Unsure
      #|3250 Poll glance B
    ),
  )
}

///|
async test "a poll checks only when the files may have changed since the stamp before it, the first of which the watch takes when it starts: Changed once the change settles, then Unsure while the stamp before it is too new to be trusted, and once its glance can be trusted it takes no full stamp" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  for name in ["same", "changed"] {
    @fs.write_file("\{dir}/\{name}.json", "{}")
  }
  // Older than the 2 s a stamp needs to be trusted.
  @async.sleep(2500)
  let checks = []
  // How many full stamps and glances the watch of changed.json has taken.
  // A glance is counted before it looks, so that once the next one is
  // counted, the poll before it is done.
  let stamps = Ref(0)
  let glances = Ref(0)
  @async.with_task_group(group => {
    for name in ["same", "changed"] {
      let changed = name == "changed"
      let watch = Watch::start(
        stamp=stamp => {
          stamp.note_file("\{dir}/\{name}.json")
          if changed {
            stamps.val += 1
          }
        },
        glance=(stamp, now) => {
          if changed {
            glances.val += 1
          }
          stamp.glance(now~)
        },
        now=@async.now(),
      )
      group.spawn_bg(no_wait=true, () => {
        watch.run(check => checks.push("\{name}: \{@debug.to_string(check)}"))
      })
    }
    // The write comes 0.625 s after the watches took their first stamp,
    // with as much room before the first poll, at 1 s, as after 0.25 s.
    // The poll's full stamp notes the new times, and the stamp at 1.25 s
    // the same, so the watch checks. The polls at 2.25 s and 3.25 s each
    // take the full stamp, since the glance they compare with, taken at 1 s
    // and 2.25 s, was taken less than 2 s after the write, and each checks,
    // since the full stamp they compare with, taken at 1.25 s and 2.25 s,
    // was too: the ones at 2.25 s only because the write came after 0.25 s.
    // The poll at 4.25 s compares its glance with one that is trusted, so
    // it takes no full stamp and checks nothing; nor does the next one.
    @async.sleep(625)
    @fs.write_file("\{dir}/changed.json", "{\"changed\": true}")
    let done = @async.with_timeout_opt(10_000, () => {
      while checks.length() < 3 {
        @async.sleep(20)
      }
      let glanced = glances.val
      while glances.val < glanced + 2 {
        @async.sleep(20)
      }
    })
    guard done is Some(_) else {
      fail("too few checks or polls in time: \{checks.join(" ")}")
    }
  })
  inspect(
    (
      $|\{checks.join("\n")}
      $|full stamps of changed.json: \{stamps.val}
    ),
    content=(
      #|changed: Changed
      #|changed: Unsure
      #|changed: Unsure
      #|full stamps of changed.json: 5
    ),
  )
}
