// The YAML writer over real Definition files: every fixture of the
// Definition-file Schema, written as YAML, reads back as the same tree. The
// smock/yaml module tests the writer on its own, but reads no files.

///|
/// The fixture directories, relative to the module root.
let fixture_directories : Array[String] = [
  "schema/v1/fixtures/valid", "schema/v1/fixtures/invalid", "schema/v1/fixtures/invalid-beyond-schema",
]

///|
async test "every Definition-file fixture, written as YAML, reads back as the same tree" {
  let mut trees = 0
  let not_trees = []
  for directory in fixture_directories {
    for name in @fs.readdir(directory, sort=true) {
      let path = "\{directory}/\{name}"
      let text = @fs.read_file(path).text()
      let tree = try {
        if name.has_suffix(".json") {
          @json.parse(text)
        } else {
          @yaml.parse(text)
        }
      } catch {
        _ => {
          not_trees.push(path)
          continue
        }
      }
      let written = @utf8.decode(@yaml.write(tree))
      // Compared as JSON text, so that member order and the digits of big
      // integers count too.
      assert_eq(@yaml.parse(written).stringify(), tree.stringify(), msg=path)
      trees += 1
    }
  }
  // The one fixture that is not JSON, which has no tree to write.
  inspect(
    not_trees.join(", "),
    content="schema/v1/fixtures/invalid/not-json.json",
  )
  assert_true(trees > 200)
}
