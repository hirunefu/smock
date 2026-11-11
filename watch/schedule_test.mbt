// When a watch polls: every second. A fake clock drives the schedule the
// way the watch loop does: it waits until the schedule's deadline, or later
// when it was busy, then asks whether a poll is due.

///|
/// Runs a schedule created at time 0, waking at each deadline, or `late`
/// milliseconds after it for each deadline listed in `late`, until
/// `until`, and lists the time of each poll that came due.
fn polls(until : Int64, late~ : Map[Int64, Int64] = {}) -> String {
  let schedule = @watch.Schedule(now=0)
  let out = []
  for ;; {
    let deadline = schedule.deadline()
    let now = deadline + late.get(deadline).unwrap_or(0)
    if now > until {
      break
    }
    if schedule.due(now) {
      out.push(now.to_string())
    }
  }
  out.join(" ")
}

///|
test "a watch polls every second" {
  inspect(polls(5000), content="1000 2000 3000 4000 5000")
}

///|
test "a poll that comes late starts the next interval from when it came" {
  inspect(polls(5000, late={ 2000: 300 }), content="1000 2300 3300 4300")
}

///|
test "nothing is due before the deadline, and a poll is due once" {
  let schedule = @watch.Schedule(now=0)
  inspect(
    (
      $|deadline \{schedule.deadline()}
      $|due at 999: \{schedule.due(999)}
      $|due at 1000: \{schedule.due(1000)}
      $|due at 1000 again: \{schedule.due(1000)}
      $|then deadline \{schedule.deadline()}
    ),
    content=(
      #|deadline 1000
      #|due at 999: false
      #|due at 1000: true
      #|due at 1000 again: false
      #|then deadline 2000
    ),
  )
}
