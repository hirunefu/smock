// When a watch stamps what it polls, and when it checks: a poll every
// second, and after a stamp that notes a change, a stamp every 250 ms until
// one notes the same as the one before it, or 10 s after the change was
// first seen. A fake clock and fake stamps drive the schedule the way the
// watch loop does: it waits until the schedule's deadline, or later when it
// was busy, asks what is due, takes the stamp, compares it with the one
// before it and tells the schedule what it noted.

///|
/// Runs a schedule created at time 0 the way a watch does, until `until`,
/// waking at each deadline, or `late` milliseconds after it for each
/// deadline listed in `late`. Things change at the times in `changes`, in
/// increasing order, and a stamp notes how many changes came at or before
/// it. Every stamp can be trusted. Lists each stamp: its time, what it was
/// due for, what it noted, and the check it called for, if any.
fn stamps(
  changes : Array[Int64],
  until : Int64,
  late~ : Map[Int64, Int64] = {},
) -> Array[String] {
  let schedule = @watch.Schedule(now=0)
  // What the stamp before noted.
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
    let noted : @watch.Noted = if notes == before { Same } else { Differs }
    before = notes
    let check = match schedule.noted(due, now, noted) {
      Some(check) => ": \{@debug.to_string(check)}"
      None => ""
    }
    out.push(
      "\{now} \{@debug.to_string(due)} \{@debug.to_string(noted)}\{check}",
    )
  }
  out
}

///|
test "without changes, a watch polls every second" {
  inspect(
    stamps([], 4000).join("\n"),
    content=(
      #|1000 Poll Same
      #|2000 Poll Same
      #|3000 Poll Same
      #|4000 Poll Same
    ),
  )
}

///|
test "a poll that comes late starts the next interval from when it came" {
  inspect(
    stamps([], 4500, late={ 2000: 300 }).join("\n"),
    content=(
      #|1000 Poll Same
      #|2300 Poll Same
      #|3300 Poll Same
      #|4300 Poll Same
    ),
  )
}

///|
test "a change is checked once a stamp 250 ms after the one that noted it notes the same, and polls go on every second from then" {
  inspect(
    stamps([500], 3500).join("\n"),
    content=(
      #|1000 Poll Differs
      #|1250 Quiet Same: Changed
      #|2250 Poll Same
      #|3250 Poll Same
    ),
  )
}

///|
test "changes less than 250 ms apart, such as files written one after the other, are checked once, after a stamp that notes the last of them" {
  inspect(
    stamps([500, 1100, 1300, 1549], 3500).join("\n"),
    content=(
      #|1000 Poll Differs
      #|1250 Quiet Differs
      #|1500 Quiet Differs
      #|1750 Quiet Differs
      #|2000 Quiet Same: Changed
      #|3000 Poll Same
    ),
  )
}

///|
test "changes that never pause for 250 ms are checked 10 s after the first stamp that noted them, and then after the next poll the same way" {
  // A change every 100 ms from 0.5 s to 29.9 s.
  let changes = Array::makei(295, i => (500 + i * 100).to_int64())
  let lines = stamps(changes, 32_000)
  let settling = lines.filter(line => line.has_suffix("Quiet Differs"))
  inspect(
    (
      $|\{lines.filter(line => !line.has_suffix("Quiet Differs")).join("\n")}
      $|and \{settling.length()} stamps of the quiet period that noted a change
    ),
    content=(
      #|1000 Poll Differs
      #|11000 Capped Differs: Changed
      #|12000 Poll Differs
      #|22000 Capped Differs: Changed
      #|23000 Poll Differs
      #|30250 Quiet Same: Changed
      #|31250 Poll Same
      #|and 106 stamps of the quiet period that noted a change
    ),
  )
}

///|
test "what a stamp calls for: a poll that notes a change starts the quiet period, one that notes the same as a stamp that cannot be trusted checks Unsure at once, and a stamp of the quiet period that notes the same, or a capped one, checks Changed" {
  let dues : Array[@watch.Due] = [Poll, Quiet, Capped]
  let noteds : Array[@watch.Noted] = [Differs, Same, Untrusted]
  let out = []
  for due in dues {
    for noted in noteds {
      let schedule = @watch.Schedule(now=0)
      guard schedule.due(1000) is Some(Poll) else { fail("no poll at 1000") }
      // A change noted at the poll, then the stamp `due` is due.
      let now : Int64 = match due {
        Poll => 1000
        Quiet => 1250
        Capped => 11_000
      }
      if now > 1000 {
        guard schedule.noted(Poll, 1000, Differs) is None else {
          fail("a check at the poll that noted the change")
        }
        guard schedule.due(now) == Some(due) else {
          fail("not \{@debug.to_string(due)} at \{now}")
        }
      }
      let check = schedule.noted(due, now, noted)
      out.push(
        "\{@debug.to_string(due)} \{@debug.to_string(noted)}: \{@debug.to_string(check)}, the next stamp \{schedule.deadline() - now} ms later",
      )
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|Poll Differs: None, the next stamp 250 ms later
      #|Poll Same: None, the next stamp 1000 ms later
      #|Poll Untrusted: Some(Unsure), the next stamp 1000 ms later
      #|Quiet Differs: None, the next stamp 250 ms later
      #|Quiet Same: Some(Changed), the next stamp 1000 ms later
      #|Quiet Untrusted: Some(Changed), the next stamp 1000 ms later
      #|Capped Differs: Some(Changed), the next stamp 1000 ms later
      #|Capped Same: Some(Changed), the next stamp 1000 ms later
      #|Capped Untrusted: Some(Changed), the next stamp 1000 ms later
    ),
  )
}

///|
test "nothing is due before the deadline, a stamp is due once, and while a change settles the deadline is the next quiet-period stamp or the end of the 10 s, whichever is earlier" {
  let schedule = @watch.Schedule(now=0)
  let due = (now : Int64) => @debug.to_string(schedule.due(now))
  let noted = (due : @watch.Due, now : Int64, noted : @watch.Noted) => {
    let check = schedule.noted(due, now, noted)
    "\{@debug.to_string(check)}, deadline \{schedule.deadline()}"
  }
  let out = ["deadline \{schedule.deadline()}"]
  out.push("due at 999: \{due(999)}")
  out.push("due at 1000: \{due(1000)}")
  out.push("due at 1000 again: \{due(1000)}")
  out.push("a change noted at 1000: \{noted(Poll, 1000, Differs)}")
  out.push("due at 1249: \{due(1249)}")
  out.push("due at 1250: \{due(1250)}")
  out.push("due at 1250 again: \{due(1250)}")
  // Another change, while the first settles, leaves the end of its 10 s
  // where it was.
  out.push("another noted at 1250: \{noted(Quiet, 1250, Differs)}")
  out.push("due at 10900: \{due(10_900)}")
  out.push("another noted at 10900: \{noted(Quiet, 10_900, Differs)}")
  out.push("due at 11000: \{due(11_000)}")
  out.push("noted at 11000: \{noted(Capped, 11_000, Differs)}")
  out.push("due at 12000: \{due(12_000)}")
  out.push("a change noted at 12000: \{noted(Poll, 12_000, Differs)}")
  out.push("due at 12250: \{due(12_250)}")
  out.push("the same noted at 12250: \{noted(Quiet, 12_250, Same)}")
  inspect(
    out.join("\n"),
    content=(
      #|deadline 1000
      #|due at 999: None
      #|due at 1000: Some(Poll)
      #|due at 1000 again: None
      #|a change noted at 1000: None, deadline 1250
      #|due at 1249: None
      #|due at 1250: Some(Quiet)
      #|due at 1250 again: None
      #|another noted at 1250: None, deadline 1500
      #|due at 10900: Some(Quiet)
      #|another noted at 10900: None, deadline 11000
      #|due at 11000: Some(Capped)
      #|noted at 11000: Some(Changed), deadline 12000
      #|due at 12000: Some(Poll)
      #|a change noted at 12000: None, deadline 12250
      #|due at 12250: Some(Quiet)
      #|the same noted at 12250: Some(Changed), deadline 13250
    ),
  )
}
