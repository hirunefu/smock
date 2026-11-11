///|
/// Watches a directory and everything under it, for a caller that reads
/// it again whole on each check, by polling it every poll interval: 1 s,
/// as `Schedule` has it by default. Which files changed does not matter: a
/// ConfigMap update, for one, swaps a `..data` symlink and changes no name
/// the caller reads.
///
/// A poll does not check when nothing the caller reads can have changed:
/// it first takes a `Stamp` of what the caller reads, and checks only when
/// the stamp may differ from the one taken at the poll before, or when the
/// watch started. So a poll that finds nothing changed reads no file's
/// contents. A directory that does not exist yet is polled the same way
/// until it appears.
///
/// It uses no file-system events: the async runtime's file watcher
/// (`@fs.Watcher`, inotify on Linux) can abort the process when files are
/// created and written in a directory it watches (moonbitlang/async#725),
/// so a watch polls alone until a release of the runtime fixes that.
/// Polling needs no C either (ADR 0001).
pub struct Watch {
  priv dir : String
  priv schedule : Schedule
  /// Notes in a stamp what the caller reads.
  priv stamp : async (Stamp) -> Unit
  /// The stamp taken last: when the watch started, or at the last poll.
  priv mut last : Stamp?
  /// Whether the last stamp noted a file time ahead of the clock, so that
  /// one that stays ahead is told once, not at every check.
  priv mut ahead : Bool
  /// A file time ahead of the clock that `run` has not told yet.
  priv mut untold_ahead : (String, Int64)?
  /// Whether `close` was called, after which `run` makes no check.
  priv mut closed : Bool
}

///|
/// Why a poll checks a watched directory.
#derive(Debug, Eq)
pub(all) enum Check {
  /// Its stamp notes something other than the last one did: a name, where
  /// a file really is, or a file's times. What the caller reads has likely
  /// changed, or at least been written again.
  Changed
  /// Its stamp notes the same as the last one did, but that one was taken
  /// too soon after a change to be trusted, or there is none, after
  /// `forget`. What the caller reads may have changed, and only reading
  /// it can tell.
  Poll
}

///|
/// Starts watching `dir`, and takes the first stamp with `stamp`, which
/// notes in a stamp what the caller reads, before the caller reads it the
/// first time. Changes from then on lead to a check once `run` runs, even
/// those made before it does. The poll interval is the one `Schedule` has
/// by default.
pub async fn Watch::Watch(
  dir : String,
  stamp~ : async (Stamp) -> Unit,
) -> Watch {
  let watch = {
    dir,
    schedule: Schedule(now=@async.now()),
    stamp,
    last: None,
    ahead: false,
    untold_ahead: None,
    closed: false,
  }
  let _ = watch.restamp()
  watch
}

///|
/// Takes a stamp, and tells which check it calls for, if any, compared
/// with the last one.
async fn Watch::restamp(self : Watch) -> Check? {
  let stamp = Stamp(now=@async.now())
  (self.stamp)(stamp)
  let check : Check? = match self.last {
    None => Some(Poll)
    Some(last) if !stamp.notes_same(last) => Some(Changed)
    Some(last) if stamp.unchanged_since(last) => None
    Some(_) => Some(Poll)
  }
  self.last = Some(stamp)
  match stamp.ahead() {
    Some(ahead) => {
      if !self.ahead {
        self.untold_ahead = Some(ahead)
      }
      self.ahead = true
    }
    None => self.ahead = false
  }
  check
}

///|
/// Calls `on_check` for each check, in turn, until the task is cancelled
/// or the watch is closed: for each poll whose stamp may have changed, as
/// `Check` tells. A stamp is taken at every poll, so that each compares
/// with what the poll before noted. A poll that falls due while `on_check`
/// runs comes once it returns.
///
/// `on_ahead` is called with a file and its time, as `Stamp::ahead` gives
/// them, when a stamp notes a file time ahead of the clock. It is called
/// again only after a stamp noted none.
pub async fn Watch::run(
  self : Watch,
  on_check : async (Check) -> Unit,
  on_ahead~ : (String, Int64) -> Unit = (_, _) => (),
) -> Unit {
  while !self.closed {
    if self.untold_ahead is Some((file, time)) {
      self.untold_ahead = None
      on_ahead(file, time)
    }
    let wait = self.schedule.deadline() - @async.now()
    if wait > 0L {
      @async.sleep(wait.to_int())
    }
    if !self.closed &&
      self.schedule.due(@async.now()) &&
      self.restamp() is Some(check) {
      on_check(check)
    }
  }
}

///|
/// Forgets the last stamp, so that the next poll checks whatever its stamp
/// notes. A caller whose check could not read all that the stamp notes,
/// such as a file that gave an I/O error, calls it so that the next poll
/// tries again: the files need not change again, and nor would the stamp.
pub fn Watch::forget(self : Watch) -> Unit {
  self.last = None
}

///|
/// Stops watching: `run` makes no check after it, and returns when it
/// wakes for the next poll.
pub fn Watch::close(self : Watch) -> Unit {
  self.closed = true
}

///|
/// The directory watched, as given to `Watch::Watch`.
pub fn Watch::dir(self : Watch) -> String {
  self.dir
}
