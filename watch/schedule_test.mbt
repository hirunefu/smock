// When a watched directory is checked: events are coalesced until they have
// been quiet for 250 ms, and the directory is polled every 10 s in case an
// event was missed. A fake clock drives the schedule the way the watch loop
// does: it waits until the schedule's deadline or the next event, whichever
// comes first, then asks what is due.

///|
/// Runs a schedule created at time 0 with the default periods, with events
/// at `events` (milliseconds, in increasing order), until `until`, and lists
/// each check that came due, with its time.
fn checks(events : Array[Int64], until : Int64) -> String {
  let schedule = @watch.Schedule(now=0)
  let out = []
  let mut next = 0
  for ;; {
    let deadline = schedule.deadline()
    let now = if next < events.length() && events[next] < deadline {
      let at = events[next]
      next += 1
      schedule.event(at)
      at
    } else {
      deadline
    }
    if now > until {
      break
    }
    if schedule.due(now) is Some(check) {
      out.push("\{now}: \{@debug.to_string(check)}")
    }
  }
  out.join("\n")
}

///|
test "an event is checked once 250 ms pass without another" {
  inspect(
    checks([1000], 5000),
    content=(
      #|1250: Changed
    ),
  )
}

///|
test "events less than 250 ms apart are coalesced into one check, 250 ms after the last" {
  inspect(
    checks([1000, 1100, 1300, 1549, 2000], 5000),
    content=(
      #|1799: Changed
      #|2250: Changed
    ),
  )
}

///|
test "without events, the directory is polled every 10 s" {
  inspect(
    checks([], 30_000),
    content=(
      #|10000: Poll
      #|20000: Poll
      #|30000: Poll
    ),
  )
}

///|
test "a check after events starts the 10 s until the next poll again" {
  inspect(
    checks([3000], 25_000),
    content=(
      #|3250: Changed
      #|13250: Poll
      #|23250: Poll
    ),
  )
}

///|
test "events that never pause for 250 ms are still checked when the poll is due" {
  let events = Array::makei(250, i => (i * 100).to_int64())
  inspect(
    checks(events, 26_000),
    content=(
      #|10000: Changed
      #|20000: Changed
      #|25150: Changed
    ),
  )
}

///|
test "nothing is due before the deadline, and the deadline is the earlier of the quiet period's end and the next poll" {
  let schedule = @watch.Schedule(now=0)
  let out = ["deadline \{schedule.deadline()}"]
  schedule.event(100)
  out.push("after an event at 100: deadline \{schedule.deadline()}")
  out.push("due at 349: \{@debug.to_string(schedule.due(349))}")
  out.push("due at 350: \{@debug.to_string(schedule.due(350))}")
  out.push("then deadline \{schedule.deadline()}")
  schedule.event(10_200)
  out.push("after an event at 10200: deadline \{schedule.deadline()}")
  inspect(
    out.join("\n"),
    content=(
      #|deadline 10000
      #|after an event at 100: deadline 350
      #|due at 349: None
      #|due at 350: Some(Changed)
      #|then deadline 10350
      #|after an event at 10200: deadline 10350
    ),
  )
}

///|
test "the quiet period and the poll interval can be set" {
  let schedule = @watch.Schedule(now=0, quiet_ms=50, poll_ms=1000)
  let out = ["deadline \{schedule.deadline()}"]
  schedule.event(100)
  out.push("after an event at 100: deadline \{schedule.deadline()}")
  out.push("due at 150: \{@debug.to_string(schedule.due(150))}")
  out.push("then deadline \{schedule.deadline()}")
  inspect(
    out.join("\n"),
    content=(
      #|deadline 1000
      #|after an event at 100: deadline 150
      #|due at 150: Some(Changed)
      #|then deadline 1150
    ),
  )
}
