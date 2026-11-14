// A Mock's `grpc` field: the Descriptor set it names in the body-file
// subdirectory, read with the Definition files.

///|
/// A Descriptor set of one file, `a.proto`, with nothing in it.
let one_file_set : Bytes = b"\x0a\x09\x0a\x07a.proto"

///|
/// Loads `a.json`, which declares `mocks`, a JSON array, with the body
/// files `body_files`.
fn load_mocks(
  mocks : String,
  body_files~ : Array[(String, Bytes)] = [],
) -> Result[@definitions.Snapshot, Array[@definitions.Diagnostic]] {
  @definitions.load({
    files: [("a.json", @utf8.encode("{ \"mocks\": \{mocks} }"))],
    body_files,
  })
}

///|
/// What `load_mocks` gives: each Mock's name and the files of its set, one
/// line each, or every problem, one per line.
fn mock_sets(
  mocks : String,
  body_files~ : Array[(String, Bytes)] = [],
) -> String {
  match load_mocks(mocks, body_files~) {
    Ok(snapshot) =>
      snapshot.mocks
      .iter()
      .map(mock => {
        let files = match mock.descriptor_set {
          Some(set) => set.files.map(file => file.name).join(", ")
          None => "no set"
        }
        "\{mock.name}: \{files}"
      })
      .collect()
      .join("\n")
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
test "a Mock's grpc.descriptorSet names a Descriptor set in the body-file subdirectory, which the Mock holds decoded" {
  inspect(
    mock_sets(
      (
        #|[{ "name": "greeter", "grpc": { "descriptorSet": "protos/greeter.binpb" } },
        #| { "name": "users" }]
      ),
      body_files=[("protos/greeter.binpb", one_file_set)],
    ),
    content=(
      #|greeter: a.proto
      #|users: no set
    ),
  )
}
