///|
/// When to check a watched directory: once its file-system events have been
/// quiet for a while, so that a burst of changes, such as a ConfigMap update
/// or a `git checkout`, gives one check; and at a fixed interval, in case an
/// event was missed. A check, whatever its cause, starts the interval
/// again.
///
/// It does no I/O and reads no clock: the caller gives it the time with
/// every call, in milliseconds. The caller waits until `deadline()` or the
/// next event, whichever comes first, reports an event with `event`, and
/// then asks `due` what to do.
pub struct Schedule {
  priv quiet_ms : Int64
  priv poll_ms : Int64
  /// When the last event came, while it waits for its quiet period.
  priv mut last_event : Int64?
  /// When the next poll is due.
  priv mut next_poll : Int64
}

///|
/// Why a directory is checked.
pub(all) enum Check {
  /// Events came, and have been quiet for the quiet period, or kept coming
  /// for a whole poll interval.
  Changed
  /// The poll interval passed without events.
  Poll
} derive(Debug, Eq)

///|
/// Creates a schedule at time `now`: the first poll is due `poll_ms` later.
///
/// - `quiet_ms` is how long events must have been quiet before a check:
///   250 ms by default.
/// - `poll_ms` is the poll interval: 10 s by default.
pub fn Schedule::Schedule(
  now~ : Int64,
  quiet_ms~ : Int32 = 250,
  poll_ms~ : Int32 = 10_000,
) -> Schedule {
  {
    quiet_ms: quiet_ms.to_int64(),
    poll_ms: poll_ms.to_int64(),
    last_event: None,
    next_poll: now + poll_ms.to_int64(),
  }
}

///|
/// Records that a file-system event came at `now`.
pub fn Schedule::event(self : Schedule, now : Int64) -> Unit {
  self.last_event = Some(now)
}

///|
/// When something can next be due: the end of the quiet period after the
/// last event, if one waits, or else the next poll, whichever is earlier.
pub fn Schedule::deadline(self : Schedule) -> Int64 {
  match self.last_event {
    Some(at) if at + self.quiet_ms < self.next_poll => at + self.quiet_ms
    _ => self.next_poll
  }
}

///|
/// The check due at `now`, if any. Once it is returned, it is no longer
/// due: the events it covers are forgotten and the next poll is due one
/// interval after `now`.
///
/// - `Changed` when events came and either have been quiet for the quiet
///   period or the poll is due: events that never pause are still checked
///   once per interval.
/// - `Poll` when the poll is due and no event came.
pub fn Schedule::due(self : Schedule, now : Int64) -> Check? {
  let check : Check? = match self.last_event {
    Some(at) if now >= at + self.quiet_ms || now >= self.next_poll =>
      Some(Changed)
    _ if now >= self.next_poll => Some(Poll)
    _ => None
  }
  if check is Some(_) {
    self.last_event = None
    self.next_poll = now + self.poll_ms
  }
  check
}
