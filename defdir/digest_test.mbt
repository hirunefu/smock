// The definition set digest as smock computes it while it serves: a step at
// a time, with a pause after each step, so that the connections it serves
// are answered in between.

///|
async test "the digest of a large set is the one DefinitionSet::digest gives, and other tasks run between its steps" {
  // 1 MiB of body file, and the 26 bytes of its frame's head: 17 steps of
  // 64 KiB at most, with a pause after each of the first 16.
  let set : @definitions.DefinitionSet = {
    files: [],
    body_files: [("large.bin", Bytes::make(1024 * 1024, b'x'))],
  }
  let mut ran = 0
  let mut done = false
  let digest = @async.with_task_group(group => {
    group.spawn_bg(() => {
      while !done {
        ran += 1
        @async.pause()
      }
    })
    let digest = @defdir.digest(set)
    done = true
    digest
  })
  inspect(
    "the same digest: \{digest == set.digest()}; the other task ran at each pause: \{ran >= 16}",
    content="the same digest: true; the other task ran at each pause: true",
  )
}
