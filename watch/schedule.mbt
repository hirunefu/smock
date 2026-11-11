///|
/// When to stamp what a watch polls. A poll comes every second
/// (`poll_ms`). When a stamp notes a change, the watch lets it settle
/// before it checks: a stamp comes every 250 ms (`quiet_ms`) instead, until
/// one notes the same as the stamp just before it, so that files written
/// one after the other give one check. If the stamps keep differing, the
/// watch checks 10 s (`settle_cap_ms`) after the change was first seen, so
/// that changes that never pause are still checked. Polls go on every
/// second from the check.
///
/// A stamp starts the interval to the next one from when it came, so one
/// that comes late moves the ones after it, and stamps never pile up.
///
/// It does no I/O and reads no clock: the caller gives it the time with
/// every call, in milliseconds. The caller waits until `deadline()`, asks
/// `due` whether a stamp is due and what for, takes it, and then tells the
/// schedule, with the time `due` was given, if the stamp noted a change
/// (`changed`) or noted the same as the one before it while a change
/// settled (`settled`).
pub struct Schedule {
  /// When the next poll is due, once no change settles.
  priv mut next_poll : Int64
  /// When the change that settles was first seen, while one does.
  priv mut seen_at : Int64?
  /// When the next stamp of the quiet period is due, while a change
  /// settles.
  priv mut next_quiet : Int64
}

///|
/// What a stamp that `Schedule::due` says is due is for.
#derive(Debug, Eq)
pub(all) enum Due {
  /// A poll: the stamp is compared with the one taken before the last
  /// check.
  Poll
  /// A stamp while a change settles: the change has settled when it notes
  /// the same as the stamp just before it.
  Quiet
  /// The last stamp of a change that has not settled 10 s after it was
  /// first seen: the watch checks whatever it notes.
  Capped
}

///|
/// The poll interval, in milliseconds.
let poll_ms : Int64 = 1000

///|
/// The quiet period: how long apart the stamps of a change that settles
/// are, in milliseconds.
let quiet_ms : Int64 = 250

///|
/// How long after it was first seen a change that has not settled is
/// checked all the same, in milliseconds.
let settle_cap_ms : Int64 = 10_000

///|
/// Creates a schedule at time `now`: the first poll is due one poll
/// interval later.
pub fn Schedule::Schedule(now~ : Int64) -> Schedule {
  { next_poll: now + poll_ms, seen_at: None, next_quiet: 0, }
}

///|
/// When the next stamp is due: while a change settles, the next stamp of
/// the quiet period or the end of the 10 s, whichever is earlier; else the
/// next poll.
pub fn Schedule::deadline(self : Schedule) -> Int64 {
  match self.seen_at {
    Some(seen) if seen + settle_cap_ms < self.next_quiet => seen + settle_cap_ms
    Some(_) => self.next_quiet
    None => self.next_poll
  }
}

///|
/// The stamp due at `now`, if any. Once it is returned, it is no longer
/// due: the next poll, or the next stamp of the quiet period, is due one
/// interval after `now`. After `Capped`, no change settles any more, and
/// the next poll is due one poll interval after `now`.
pub fn Schedule::due(self : Schedule, now : Int64) -> Due? {
  match self.seen_at {
    Some(seen) if now >= seen + settle_cap_ms => {
      self.seen_at = None
      self.next_poll = now + poll_ms
      Some(Capped)
    }
    Some(_) if now >= self.next_quiet => {
      self.next_quiet = now + quiet_ms
      Some(Quiet)
    }
    Some(_) => None
    None if now >= self.next_poll => {
      self.next_poll = now + poll_ms
      Some(Poll)
    }
    None => None
  }
}

///|
/// Tells the schedule that the stamp due at `now` noted a change: from a
/// poll, the change starts to settle, and the next stamp is due one quiet
/// period after `now`. While a change settles, the 10 s still count from
/// when it was first seen.
pub fn Schedule::changed(self : Schedule, now : Int64) -> Unit {
  if self.seen_at is None {
    self.seen_at = Some(now)
    self.next_quiet = now + quiet_ms
  }
}

///|
/// Tells the schedule that the stamp due at `now` noted the same as the
/// one before it while a change settled: the watch checks, and the next
/// poll is due one poll interval after `now`.
pub fn Schedule::settled(self : Schedule, now : Int64) -> Unit {
  self.seen_at = None
  self.next_poll = now + poll_ms
}
