///|
/// When to stamp what a watch polls, and which stamps lead to a check. A
/// poll comes every second (`poll_ms`). When a stamp notes a change, the
/// watch lets it settle before it checks: a stamp comes every 250 ms
/// (`quiet_ms`) instead, until one notes the same as the stamp just before
/// it, so that files written one after the other give one check. If the
/// stamps keep differing, the watch checks 10 s (`settle_cap_ms`) after
/// the change was first seen, so that changes that never pause are still
/// checked. Polls go on every second from the check.
///
/// A stamp starts the interval to the next one from when it came, so one
/// that comes late moves the ones after it, and stamps never pile up.
///
/// It does no I/O and reads no clock: the caller gives it the time with
/// every call, in milliseconds. The caller waits until `deadline()`, asks
/// `due` whether a stamp is due and what for, takes it, compares it with
/// the stamp it took before, and tells the schedule what it noted
/// (`noted`), with the time `due` was given. That tells whether to check.
/// At a poll, a glance that notes the same as the one before it can do in
/// place of the stamp, as `Watch` has it: it tells the schedule `Same`.
pub struct Schedule {
  /// Whether a change settles, and when the next stamp is due.
  priv mut phase : Phase
}

///|
/// What a schedule waits for.
priv enum Phase {
  /// No change settles: the next poll is due at `next`.
  Polling(next~ : Int64)
  /// A change first seen at `seen` settles: the next stamp of the quiet
  /// period is due at `next`.
  Settling(seen~ : Int64, next~ : Int64)
}

///|
/// What a stamp that `Schedule::due` says is due is for.
#derive(Debug, Eq)
pub(all) enum Due {
  /// A poll, every poll interval.
  Poll
  /// A stamp while a change settles: the change has settled when it notes
  /// the same as the stamp just before it.
  Quiet
  /// The last stamp of a change that has not settled 10 s after it was
  /// first seen: the watch checks whatever it notes.
  Capped
}

///|
/// What a stamp noted, compared with the stamp taken just before it.
#derive(Debug, Eq)
pub(all) enum Noted {
  /// Something other than the stamp before it: a change.
  Differs
  /// The same as the stamp before it, which can be trusted: nothing
  /// changed.
  Same
  /// The same as the stamp before it, but that one was taken too soon
  /// after a change to be trusted, or there is none, after
  /// `Watch::forget`: only a read can tell whether anything changed.
  Untrusted
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
  { phase: Polling(next=now + poll_ms), }
}

///|
/// When the next stamp is due: while a change settles, the next stamp of
/// the quiet period or the end of the 10 s, whichever is earlier; else the
/// next poll.
pub fn Schedule::deadline(self : Schedule) -> Int64 {
  match self.phase {
    Polling(next~) => next
    Settling(seen~, next~) if seen + settle_cap_ms < next =>
      seen + settle_cap_ms
    Settling(next~, ..) => next
  }
}

///|
/// The stamp due at `now`, if any. Once it is returned, it is no longer
/// due: the next poll, or the next stamp of the quiet period, is due one
/// interval after `now`. After `Capped`, no change settles any more, and
/// the next poll is due one poll interval after `now`.
pub fn Schedule::due(self : Schedule, now : Int64) -> Due? {
  match self.phase {
    Settling(seen~, ..) if now >= seen + settle_cap_ms => {
      self.phase = Polling(next=now + poll_ms)
      Some(Capped)
    }
    Settling(seen~, next~) if now >= next => {
      self.phase = Settling(seen~, next=now + quiet_ms)
      Some(Quiet)
    }
    Polling(next~) if now >= next => {
      self.phase = Polling(next=now + poll_ms)
      Some(Poll)
    }
    _ => None
  }
}

///|
/// Tells the schedule what the stamp `due` at `now` noted, and tells which
/// check that calls for, if any:
///
/// - A poll that notes a change checks nothing yet: the change starts to
///   settle, and the next stamp is due one quiet period after `now`.
/// - A poll that notes the same as a stamp that can be trusted checks
///   nothing.
/// - A poll that notes the same as a stamp that cannot be trusted, or that
///   has none to compare with, checks at once, `Unsure`, with no quiet
///   period: no stamp shows a change under way.
/// - A stamp of the quiet period that notes a change checks nothing: the
///   change goes on settling, and the 10 s still count from when it was
///   first seen.
/// - One that notes the same, trusted or not, has settled: the watch
///   checks, `Changed`, even when the stamps note the same as before the
///   change, since something was written. The next poll is due one poll
///   interval after `now`.
/// - A `Capped` stamp checks, `Changed`, whatever it notes.
pub fn Schedule::noted(
  self : Schedule,
  due : Due,
  now : Int64,
  noted : Noted,
) -> Check? {
  match (due, noted) {
    (Poll, Differs) => {
      self.phase = Settling(seen=now, next=now + quiet_ms)
      None
    }
    (Poll, Same) | (Quiet, Differs) => None
    (Poll, Untrusted) => Some(Unsure)
    (Quiet, Same | Untrusted) => {
      self.phase = Polling(next=now + poll_ms)
      Some(Changed)
    }
    (Capped, _) => Some(Changed)
  }
}
