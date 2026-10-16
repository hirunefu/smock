// The stamp of a definitions directory, which a poll compares with the last
// poll's before it reads the directory: it changes with every change that a
// read could see, and only then.

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
  // Far enough after the files were written for each stamp to be trusted.
  let at = @async.now() + 60_000
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
    out.push("\{name}: unchanged \{next.unchanged_since(last)}")
    last = next
  }
  inspect(
    out.join("\n"),
    content=(
      #|nothing: unchanged true
      #|a file that is not read edited: unchanged true
      #|an entry whose name starts with . added: unchanged true
      #|a Definition file written again with the same bytes: unchanged false
      #|a Definition file added: unchanged false
      #|a Definition file renamed: unchanged false
      #|a Definition file removed: unchanged false
      #|a body file edited: unchanged false
      #|a body file added: unchanged false
      #|a body file removed: unchanged false
      #|the ..data symlink swapped: unchanged false
      #|a Definition file's symlink pointed at a file with the very same times: unchanged false
      #|a Definition file replaced by a directory: unchanged false
    ),
  )
}

///|
async test "the stamp of a definitions directory notes whether it exists" {
  let parent = @fs.tmpdir(prefix="smock-stamp-")
  defer @fs.rmdir(parent, recursive=true)
  let dir = "\{parent}/later"
  let at = @async.now() + 60_000
  let missing = stamp_of(dir, at~)
  let still_missing = stamp_of(dir, at~)
  @fs.mkdir(dir)
  inspect(
    (
      $|still missing: unchanged \{still_missing.unchanged_since(missing)}
      $|created, empty: unchanged \{stamp_of(dir, at~).unchanged_since(missing)}
    ),
    content=(
      #|still missing: unchanged true
      #|created, empty: unchanged false
    ),
  )
}
