///|
/// When to poll what a watch polls: every second (`poll_ms`). A poll starts
/// the interval again from when it came, so a poll that comes late moves
/// the ones after it, and polls never pile up.
///
/// It does no I/O and reads no clock: the caller gives it the time with
/// every call, in milliseconds. The caller waits until `deadline()`, then
/// asks `due` whether to poll.
pub struct Schedule {
  /// When the next poll is due.
  priv mut next_poll : Int64
}

///|
/// The poll interval, in milliseconds.
let poll_ms : Int64 = 1000

///|
/// Creates a schedule at time `now`: the first poll is due one poll
/// interval later.
pub fn Schedule::Schedule(now~ : Int64) -> Schedule {
  { next_poll: now + poll_ms, }
}

///|
/// When the next poll is due.
pub fn Schedule::deadline(self : Schedule) -> Int64 {
  self.next_poll
}

///|
/// Whether a poll is due at `now`. Once it says so, the poll is no longer
/// due: the next one is due one interval after `now`.
pub fn Schedule::due(self : Schedule, now : Int64) -> Bool {
  guard now >= self.next_poll else { return false }
  self.next_poll = now + poll_ms
  true
}
