///|
/// What a poll compares with the last poll's before it reads anything, so
/// that a poll that finds nothing changed costs a few calls for file
/// metadata instead of reading and digesting every file. The caller notes
/// in it, in the order it would read them, the names in each directory it
/// would list and each file it would read, whose modification and change
/// times are noted, after following symlinks.
///
/// A file's contents cannot change without its change time (ctime)
/// changing: a write sets it, a new file gets the current time, and no call
/// sets it back. So a file replaced by another, such as by a ConfigMap
/// update, which swaps the `..data` symlink, shows as new times too. The
/// size would add nothing, since a new size comes with a new change time.
/// The inode would add only a file swapped for another with the very same
/// times, such as two versions written within one clock tick and swapped
/// back and forth. moonbitlang/async gives neither for a path after
/// following symlinks, so comparing them would need C, which ADR 0001
/// keeps to TLS.
///
/// File times are coarse, though: a change made soon after another can get
/// the same time. So a stamp is trusted only once it was taken a while
/// after the newest time it notes (`settle_ms`): any change after that gets
/// a later time. A modification time ahead of the clock by more than that
/// does not count, so that one set into the future, as by an archive made
/// on a host whose clock ran ahead, does not keep every stamp from being
/// trusted: the call that set it set the change time to the time then, and
/// that counts.
pub struct Stamp {
  /// When it was taken, in milliseconds since the epoch: before the caller
  /// notes anything.
  priv taken_at : Int64
  /// What the caller noted, in order.
  priv notes : Array[String]
  /// The newest file time noted that counts, in milliseconds since the
  /// epoch, rounded up, or 0 before any.
  priv mut newest : Int64
  /// The first file noted with a time ahead of the clock by more than
  /// `settle_ms`, and that time.
  priv mut ahead : (String, Int64)?
}

///|
/// How long after the newest file time it notes a stamp must have been
/// taken to be trusted: longer than the coarsest file times in common use
/// (FAT keeps them to 2 s, ext3 and HFS+ to 1 s) and than the coarse clock
/// the kernel stamps files with.
let settle_ms : Int64 = 2000

///|
/// Starts a stamp taken at `now`, in milliseconds since the epoch, before
/// anything is noted.
pub fn Stamp::Stamp(now~ : Int64) -> Stamp {
  { taken_at: now, notes: [], newest: 0, ahead: None, }
}

///|
/// Notes `note`, such as the names in a directory or why it could not be
/// listed.
pub fn Stamp::note(self : Stamp, note : String) -> Unit {
  self.notes.push(note)
}

///|
/// Notes the file at `path`: its modification and change times, after
/// following symlinks, or why they cannot be had.
pub async fn Stamp::note_file(self : Stamp, path : String) -> Unit {
  try (@fs.mtime(path), @fs.ctime(path)) catch {
    err => self.notes.push("\{path}: \{err}")
  } noraise {
    (modified, changed) => {
      self.notes.push(
        "\{path}: \{modified.0}.\{modified.1} \{changed.0}.\{changed.1}",
      )
      let modified = ms_up(modified)
      let changed = ms_up(changed)
      // A time later than this was set by a clock ahead of this one.
      let clock_ahead = self.taken_at + settle_ms
      if modified <= clock_ahead && modified > self.newest {
        self.newest = modified
      }
      if changed > self.newest {
        self.newest = changed
      }
      let latest = if modified > changed { modified } else { changed }
      if latest > clock_ahead && self.ahead is None {
        self.ahead = Some((path, latest))
      }
    }
  }
}

///|
/// A file time, seconds and nanoseconds, in milliseconds, rounded up.
fn ms_up(time : (Int64, Int)) -> Int64 {
  time.0 * 1000 + ((time.1 + 999_999) / 1_000_000).to_int64()
}

///|
/// The first file noted whose modification or change time is ahead of the
/// clock by more than `settle_ms`, as the caller named it, and that time,
/// the later of the two, in milliseconds since the epoch. A modification
/// time ahead does not keep the stamp from being trusted; a change time
/// ahead, which only a clock set back since can give, does, until the
/// clock passes it.
pub fn Stamp::ahead(self : Stamp) -> (String, Int64)? {
  self.ahead
}

///|
/// Whether nothing `self` notes can have changed since `last` was taken:
/// they note the same, and `last` is trusted, having been taken at least
/// `settle_ms` after the newest file time it notes.
pub fn Stamp::unchanged_since(self : Stamp, last : Stamp) -> Bool {
  last.newest <= last.taken_at - settle_ms && self.notes == last.notes
}
