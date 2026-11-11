///|
/// Polls what a caller reads, for a caller that reads it again whole on
/// each check: every poll interval, 1 s, as `Schedule` has it, it takes a
/// `Stamp`, in which the `stamp` function given to `Watch::Watch` notes
/// what the caller reads, and checks only when the stamp may differ from
/// the one taken before it, the first of which it takes when it starts. So
/// a poll that finds nothing changed reads no file's contents. Which files
/// changed does not matter: a ConfigMap update, for one, swaps a `..data`
/// symlink and changes no name the caller reads. What the stamp notes need
/// not exist yet: a directory that does not is polled the same way until
/// it appears.
///
/// A change is checked once it has settled: after a stamp that notes a
/// change, the watch stamps again every 250 ms, and checks once a stamp
/// notes the same as the one before it, so that files written one after
/// the other give one check, of them all. Changes that never pause are
/// checked 10 s after the first was seen.
///
/// It uses no file-system events: the async runtime's file watcher can
/// abort the process (moonbitlang/async#725), so a watch polls alone until
/// a release of the runtime fixes that. Polling needs no C either (ADR
/// 0001).
pub struct Watch {
  priv schedule : Schedule
  /// Notes in a stamp what the caller reads.
  priv stamp : async (Stamp) -> Unit
  /// The stamp taken last, which the next one is compared with, or none
  /// after `forget`.
  priv mut last : Stamp?
  /// Whether the last stamp noted a file time ahead of the clock, so that
  /// one that stays ahead is told once, not at every check.
  priv mut ahead : Bool
  /// A file time ahead of the clock that `run` has not told yet.
  priv mut untold_ahead : (String, Int64)?
}

///|
/// Why a watch checks what it polls.
#derive(Debug, Eq)
pub(all) enum Check {
  /// A stamp noted something other than the one before it did: a name,
  /// where a file really is, or a file's times. The change has settled
  /// since, or has gone on for 10 s. What the caller reads has likely
  /// changed, or at least been written again.
  Changed
  /// A poll's stamp notes the same as the one before it, but cannot tell
  /// whether anything changed: that one was taken too soon after a change
  /// to be trusted, or there is none, after `forget`. Only reading what the
  /// caller reads can tell. It comes at the poll, with no quiet period.
  Unsure
}

///|
/// Starts a watch of what `stamp` notes in a stamp, and takes the first
/// stamp, before the caller reads it the first time. Changes from then on
/// lead to a check once `run` runs, even those made before it does.
pub async fn Watch::Watch(stamp~ : async (Stamp) -> Unit) -> Watch {
  let watch = {
    schedule: Schedule(now=@async.now()),
    stamp,
    last: None,
    ahead: false,
    untold_ahead: None,
  }
  watch.last = Some(watch.take())
  watch
}

///|
/// Takes a stamp, and keeps track of whether it notes a file time ahead of
/// the clock, for `run` to tell.
async fn Watch::take(self : Watch) -> Stamp {
  let stamp = Stamp(now=@async.now())
  (self.stamp)(stamp)
  match stamp.ahead() {
    Some(ahead) => {
      if !self.ahead {
        self.untold_ahead = Some(ahead)
      }
      self.ahead = true
    }
    None => self.ahead = false
  }
  stamp
}

///|
/// Takes the stamp `due` at `now`, compares it with the stamp taken before
/// it, and tells which check that calls for, if any, as `Schedule::noted`
/// has it. Each stamp is kept for the next one to compare with. So after a
/// check, the next poll compares with the stamp taken just before the
/// check read, and trusts it only once it is old enough.
async fn Watch::restamp(self : Watch, due : Due, now : Int64) -> Check? {
  let stamp = self.take()
  let noted : Noted = match self.last {
    Some(last) if !stamp.notes_same(last) => Differs
    Some(last) if last.trusted() => Same
    _ => Untrusted
  }
  self.last = Some(stamp)
  self.schedule.noted(due, now, noted)
}

///|
/// Calls `on_check` for each check, in turn, until the task is cancelled:
/// for each stamp that calls for one, as `Check` tells: once a change has
/// settled, or at a poll that cannot tell whether anything changed. A
/// stamp that falls due while `on_check` runs comes once it returns.
///
/// `on_ahead` is called with a file and its time, as `Stamp::ahead` gives
/// them, when a stamp notes a file time ahead of the clock. It is called
/// again only after a stamp noted none.
pub async fn Watch::run(
  self : Watch,
  on_check : async (Check) -> Unit,
  on_ahead~ : (String, Int64) -> Unit = (_, _) => (),
) -> Unit {
  for ;; {
    if self.untold_ahead is Some((file, time)) {
      self.untold_ahead = None
      on_ahead(file, time)
    }
    let wait = self.schedule.deadline() - @async.now()
    if wait > 0L {
      @async.sleep(wait.to_int())
    }
    let now = @async.now()
    if self.schedule.due(now) is Some(due) &&
      self.restamp(due, now) is Some(check) {
      on_check(check)
    }
  }
}

///|
/// Forgets the stamp taken last, so that the next poll has none to compare
/// with and checks, whatever its stamp notes. A caller whose check could
/// not read all that the stamp notes, such as a file that gave an I/O
/// error, calls it so that the next poll tries again: the files need not
/// change again, and nor would the stamp.
pub fn Watch::forget(self : Watch) -> Unit {
  self.last = None
}
