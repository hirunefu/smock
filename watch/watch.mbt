///|
/// Watches a directory and everything under it, for a caller that reads
/// it again whole on each check. Which files changed does not matter: a
/// ConfigMap update, for one, swaps a `..data` symlink and changes no name
/// the caller reads. Checks follow a `Schedule`: once events have been
/// quiet for the quiet period, and every poll interval in case an event was
/// missed.
///
/// A poll does not check when nothing the caller reads can have changed:
/// it first takes a `Stamp` of what the caller reads, and checks only when
/// the stamp may differ from the one taken before the last check, whatever
/// caused that check, or when the watch started. So a poll that finds
/// nothing changed reads no file.
///
/// The events come from the async runtime's file watcher (inotify on
/// Linux), so no C is needed (ADR 0001). A directory that does not exist
/// yet is only polled until it appears. One that cannot be watched for
/// another reason, such as the inotify limits, is only polled too, and the
/// reason is reported. Watching is tried again at each check.
pub struct Watch {
  priv dir : String
  priv schedule : Schedule
  /// Notes in a stamp what the caller reads.
  priv stamp : async (Stamp) -> Unit
  /// The stamp taken last: when the watch started, or before the last
  /// check.
  priv mut last : Stamp?
  /// The file watcher, while the directory is watched.
  priv mut watcher : @fs.Watcher?
  /// Whether watching has failed since it last worked, so that a directory
  /// that stays unwatchable is reported once, not at every check.
  priv mut failing : Bool
  /// A failure that `run` has not reported yet.
  priv mut unreported : Error?
}

///|
/// Starts watching `dir`, and takes the first stamp with `stamp`, which
/// notes in a stamp what the caller reads, before the caller reads it the
/// first time. Changes from then on lead to a check once `run` runs, even
/// those made before it does. The quiet period and the poll interval are
/// those `Schedule` has by default.
pub async fn Watch::Watch(
  dir : String,
  stamp~ : async (Stamp) -> Unit,
) -> Watch {
  let watch = {
    dir,
    schedule: Schedule(now=@async.now()),
    stamp,
    last: None,
    watcher: None,
    failing: false,
    unreported: None,
  }
  watch.start()
  let _ = watch.restamp()
  watch
}

///|
/// Takes a stamp, and tells whether what it notes may have changed since
/// the last one.
async fn Watch::restamp(self : Watch) -> Bool {
  let stamp = Stamp(now=@async.now())
  (self.stamp)(stamp)
  let changed = !(self.last is Some(last) && stamp.unchanged_since(last))
  self.last = Some(stamp)
  changed
}

///|
/// Starts the file watcher, or notes why it cannot start.
async fn Watch::start(self : Watch) -> Unit {
  try @fs.Watcher(self.dir) catch {
    err => {
      let exists = @fs.exists(self.dir) catch { _ => true }
      if exists {
        self.failed(err)
      }
    }
  } noraise {
    watcher => {
      self.watcher = Some(watcher)
      self.failing = false
    }
  }
}

///|
fn Watch::failed(self : Watch, err : Error) -> Unit {
  if !self.failing {
    self.unreported = Some(err)
  }
  self.failing = true
}

///|
/// Calls `on_check` for each check, in turn, until the task is cancelled:
/// for each check after events, and for each poll whose stamp may have
/// changed. A stamp is taken before every check, so that a poll compares
/// with what the last check read. Events that come while `on_check` runs
/// lead to another check.
///
/// `on_error` is called with the reason when the directory exists but
/// cannot be watched, or watching stops: it is only polled from then on.
/// It is called again only after watching has worked once more.
pub async fn Watch::run(
  self : Watch,
  on_check : async (Check) -> Unit,
  on_error? : (Error) -> Unit = _ => (),
) -> Unit {
  for ;; {
    if self.unreported is Some(err) {
      self.unreported = None
      on_error(err)
    }
    let wait = self.schedule.deadline() - @async.now()
    if wait > 0L {
      match self.watcher {
        Some(watcher) => {
          let event = try
            @async.with_timeout_opt(wait.to_int(), () => watcher.wait_any())
          catch {
            err => {
              watcher.close()
              self.watcher = None
              self.failed(err)
              None
            }
          } noraise {
            event => event
          }
          if event is Some(_) {
            self.schedule.event(@async.now())
          }
        }
        None => @async.sleep(wait.to_int())
      }
    }
    if self.schedule.due(@async.now()) is Some(check) {
      if self.watcher is None {
        self.start()
      }
      let changed = self.restamp()
      if check is Changed || changed {
        on_check(check)
      }
    }
  }
}

///|
/// Stops watching.
pub fn Watch::close(self : Watch) -> Unit {
  if self.watcher is Some(watcher) {
    watcher.close()
    self.watcher = None
  }
}

///|
/// The directory watched, as given to `Watch::Watch`.
pub fn Watch::dir(self : Watch) -> String {
  self.dir
}
