///|
/// When to poll a watched directory: every poll interval, one second by
/// default. A poll starts the interval again from when it came, so a poll
/// that comes late moves the ones after it, and polls never pile up.
///
/// It does no I/O and reads no clock: the caller gives it the time with
/// every call, in milliseconds. The caller waits until `deadline()`, then
/// asks `due` whether to poll.
pub struct Schedule {
  priv poll_ms : Int64
  /// When the next poll is due.
  priv mut next_poll : Int64
}

///|
/// Creates a schedule at time `now`: the first poll is due `poll_ms` later.
/// `poll_ms` is the poll interval: 1 s by default.
pub fn Schedule::Schedule(now~ : Int64, poll_ms~ : Int32 = 1000) -> Schedule {
  { poll_ms: poll_ms.to_int64(), next_poll: now + poll_ms.to_int64(), }
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
  self.next_poll = now + self.poll_ms
  true
}
