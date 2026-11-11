// The stamp of a definitions directory, which a watch compares with the
// stamp before it, so that it reads the directory only when something may
// have changed: it changes with every change that a read could see, and
// only then.

///|
/// Writes `text` to `dir/path`, creating the directories on the way.
async fn write(dir : String, path : String, text : String) -> Unit {
  let parts = path.split("/").collect()
  let mut parent = dir
  for part in parts[:parts.length() - 1] {
    parent = "\{parent}/\{part}"
    @fs.mkdir(parent, allow_exist=true)
  }
  @fs.write_file("\{dir}/\{path}", text)
}

///|
/// The stamp of the definitions directory `dir`, with the body files in
/// `files`, as a poll takes it at `at`.
async fn stamp_of(dir : String, at~ : Int64) -> @watch.Stamp {
  let stamp = @watch.Stamp(now=at)
  @defdir.stamp(stamp, dir, body_file_dir="files")
  stamp
}

///|
/// Points `dir/..data` at a new version `..<version>` that holds `files`, as
/// a ConfigMap update does, with an atomic rename of a symlink.
async fn configmap_update(
  dir : String,
  version : String,
  files : Array[(String, String)],
) -> Unit {
  for file in files {
    write(dir, "..\{version}/\{file.0}", file.1)
  }
  @fs.symlink(target="..\{version}", "\{dir}/..data_tmp")
  @fs.rename("\{dir}/..data_tmp", "\{dir}/..data")
}

///|
async test "the stamp of a definitions directory changes with each change a read could see, and not otherwise" {
  let dir = @fs.tmpdir(prefix="smock-stamp-")
  defer @fs.rmdir(dir, recursive=true)
  write(dir, "mocks.json", "{}")
  write(dir, "users.yaml", "{}")
  write(dir, "files/users/1.json", "Alice")
  write(dir, "README.md", "")
  configmap_update(dir, "v1", [("orders.json", "{}")])
  @fs.symlink(target="..data/orders.json", "\{dir}/orders.json")
  // Two releases of a file with the very same times, as two versions a
  // script wrote within one clock tick can have: here, two names for one
  // file.
  write(dir, ".releases/a/payments.json", "{}")
  @fs.mkdir("\{dir}/.releases/b")
  let status = @process.run("ln", [
    "\{dir}/.releases/a/payments.json",
    "\{dir}/.releases/b/payments.json",
  ])
  guard status == 0 else { fail("ln exited with \{status}") }
  @fs.symlink(target=".releases/a/payments.json", "\{dir}/payments.json")
  let at = @async.now()
  let changes : Array[(String, async () -> Unit)] = [
    ("nothing", () => ()),
    ("a file that is not read edited", () => write(dir, "README.md", "x")),
    (
      "an entry whose name starts with . added",
      () => write(dir, ".hidden.json", "{}"),
    ),
    (
      "a Definition file written again with the same bytes",
      () => write(dir, "mocks.json", "{}"),
    ),
    ("a Definition file added", () => write(dir, "more.yml", "{}")),
    (
      "a Definition file renamed",
      () => @fs.rename("\{dir}/more.yml", "\{dir}/most.yml"),
    ),
    ("a Definition file removed", () => @fs.remove("\{dir}/most.yml")),
    ("a body file edited", () => write(dir, "files/users/1.json", "Bob")),
    ("a body file added", () => write(dir, "files/users/2.json", "Carol")),
    ("a body file removed", () => @fs.remove("\{dir}/files/users/2.json")),
    (
      "the ..data symlink swapped",
      () => configmap_update(dir, "v2", [("orders.json", "{}")]),
    ),
    (
      "a Definition file's symlink pointed at a file with the very same times",
      () => {
        @fs.symlink(target=".releases/b/payments.json", "\{dir}/next")
        @fs.rename("\{dir}/next", "\{dir}/payments.json")
      },
    ),
    (
      "a Definition file replaced by a directory",
      () => {
        @fs.remove("\{dir}/users.yaml")
        @fs.mkdir("\{dir}/users.yaml")
      },
    ),
  ]
  let out = []
  let mut last = stamp_of(dir, at~)
  for change in changes {
    let (name, make) = change
    // Later than the coarsest clock tick, so that each change gets a time
    // of its own.
    @async.sleep(20)
    make()
    let next = stamp_of(dir, at~)
    out.push("\{name}: same \{next.notes_same(last)}")
    last = next
  }
  inspect(
    out.join("\n"),
    content=(
      #|nothing: same true
      #|a file that is not read edited: same true
      #|an entry whose name starts with . added: same true
      #|a Definition file written again with the same bytes: same false
      #|a Definition file added: same false
      #|a Definition file renamed: same false
      #|a Definition file removed: same false
      #|a body file edited: same false
      #|a body file added: same false
      #|a body file removed: same false
      #|the ..data symlink swapped: same false
      #|a Definition file's symlink pointed at a file with the very same times: same false
      #|a Definition file replaced by a directory: same false
    ),
  )
}

///|
async test "the stamp of a definitions directory notes whether it exists" {
  let parent = @fs.tmpdir(prefix="smock-stamp-")
  defer @fs.rmdir(parent, recursive=true)
  let dir = "\{parent}/later"
  let at = @async.now()
  let missing = stamp_of(dir, at~)
  let still_missing = stamp_of(dir, at~)
  @fs.mkdir(dir)
  inspect(
    (
      $|still missing: same \{still_missing.notes_same(missing)}
      $|created, empty: same \{stamp_of(dir, at~).notes_same(missing)}
    ),
    content=(
      #|still missing: same true
      #|created, empty: same false
    ),
  )
}
