// When a watch stamps what it polls: a poll every second, and after a
// stamp that notes a change, a stamp every 250 ms until one notes the same
// as the one before it, or 10 s after the change was first seen. A fake
// clock and fake stamps drive the schedule the way the watch loop does: it
// waits until the schedule's deadline, or later when it was busy, asks what
// is due, takes the stamp and tells the schedule what it noted.

///|
/// Runs a schedule created at time 0 the way a watch does, until `until`,
/// waking at each deadline, or `late` milliseconds after it for each
/// deadline listed in `late`. Things change at the times in `changes`, in
/// increasing order, and a stamp notes how many changes came at or before
/// it. Lists each stamp: its time, what it was due for, and whether it
/// noted a change or the watch checks after it.
fn stamps(
  changes : Array[Int64],
  until : Int64,
  late~ : Map[Int64, Int64] = {},
) -> Array[String] {
  let schedule = @watch.Schedule(now=0)
  // What the stamp kept last noted, and, while a change settles, what the
  // stamp just before noted.
  let mut kept = 0
  let mut before = 0
  let out = []
  for ;; {
    let deadline = schedule.deadline()
    let now = deadline + late.get(deadline).unwrap_or(0)
    if now > until {
      break
    }
    guard schedule.due(now) is Some(due) else { continue }
    let notes = changes.filter(at => at <= now).length()
    let what = match due {
      Poll if notes == kept => ""
      Quiet if notes == before => {
        schedule.settled(now)
        kept = notes
        ": check"
      }
      Poll | Quiet => {
        schedule.changed(now)
        before = notes
        ": changed"
      }
      Capped => {
        kept = notes
        ": check"
      }
    }
    out.push("\{now} \{@debug.to_string(due)}\{what}")
  }
  out
}

///|
test "without changes, a watch polls every second" {
  inspect(
    stamps([], 4000).join("\n"),
    content=(
      #|1000 Poll
      #|2000 Poll
      #|3000 Poll
      #|4000 Poll
    ),
  )
}

///|
test "a poll that comes late starts the next interval from when it came" {
  inspect(
    stamps([], 4500, late={ 2000: 300 }).join("\n"),
    content=(
      #|1000 Poll
      #|2300 Poll
      #|3300 Poll
      #|4300 Poll
    ),
  )
}

///|
test "a change is checked once a stamp 250 ms after the one that noted it notes the same, and polls go on every second from then" {
  inspect(
    stamps([500], 3500).join("\n"),
    content=(
      #|1000 Poll: changed
      #|1250 Quiet: check
      #|2250 Poll
      #|3250 Poll
    ),
  )
}

///|
test "changes less than 250 ms apart, such as files written one after the other, are checked once, after a stamp that notes the last of them" {
  inspect(
    stamps([500, 1100, 1300, 1549], 3500).join("\n"),
    content=(
      #|1000 Poll: changed
      #|1250 Quiet: changed
      #|1500 Quiet: changed
      #|1750 Quiet: changed
      #|2000 Quiet: check
      #|3000 Poll
    ),
  )
}

///|
test "changes that never pause for 250 ms are checked 10 s after the first stamp that noted them, and then after the next poll the same way" {
  // A change every 100 ms from 0.5 s to 29.9 s.
  let changes = Array::makei(295, i => (500 + i * 100).to_int64())
  let stamps = stamps(changes, 32_000)
  let quiet = stamps.filter(stamp => stamp.contains("Quiet")).length()
  inspect(
    (
      $|\{stamps.filter(stamp => !stamp.contains("Quiet")).join("\n")}
      $|then \{stamps.filter(stamp => stamp.contains("Quiet: check")).join("")}
      $|quiet-period stamps: \{quiet}
    ),
    content=(
      #|1000 Poll: changed
      #|11000 Capped: check
      #|12000 Poll: changed
      #|22000 Capped: check
      #|23000 Poll: changed
      #|31250 Poll
      #|then 30250 Quiet: check
      #|quiet-period stamps: 107
    ),
  )
}

///|
test "nothing is due before the deadline, a stamp is due once, and while a change settles the deadline is the next quiet-period stamp or the end of the 10 s, whichever is earlier" {
  let schedule = @watch.Schedule(now=0)
  let due = (now : Int64) => @debug.to_string(schedule.due(now))
  let out = ["deadline \{schedule.deadline()}"]
  out.push("due at 999: \{due(999)}")
  out.push("due at 1000: \{due(1000)}")
  out.push("due at 1000 again: \{due(1000)}")
  schedule.changed(1000)
  out.push("after a change at 1000: deadline \{schedule.deadline()}")
  out.push("due at 1249: \{due(1249)}")
  out.push("due at 1250: \{due(1250)}")
  out.push("due at 1250 again: \{due(1250)}")
  // Another change, while the first settles, leaves the end of its 10 s
  // where it was.
  schedule.changed(1250)
  out.push("after another at 1250: deadline \{schedule.deadline()}")
  out.push("due at 10900: \{due(10_900)}")
  out.push("then deadline \{schedule.deadline()}")
  out.push("due at 11000: \{due(11_000)}")
  out.push("then deadline \{schedule.deadline()}")
  out.push("due at 12000: \{due(12_000)}")
  schedule.changed(12_000)
  out.push("after a change at 12000: deadline \{schedule.deadline()}")
  out.push("due at 12250: \{due(12_250)}")
  schedule.settled(12_250)
  out.push("settled at 12250: deadline \{schedule.deadline()}")
  inspect(
    out.join("\n"),
    content=(
      #|deadline 1000
      #|due at 999: None
      #|due at 1000: Some(Poll)
      #|due at 1000 again: None
      #|after a change at 1000: deadline 1250
      #|due at 1249: None
      #|due at 1250: Some(Quiet)
      #|due at 1250 again: None
      #|after another at 1250: deadline 1500
      #|due at 10900: Some(Quiet)
      #|then deadline 11000
      #|due at 11000: Some(Capped)
      #|then deadline 12000
      #|due at 12000: Some(Poll)
      #|after a change at 12000: deadline 12250
      #|due at 12250: Some(Quiet)
      #|settled at 12250: deadline 13250
    ),
  )
}
