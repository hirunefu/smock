// Golden files of `smock import-openapi`: documents whose imports are
// committed with the repository, so that every change to what the import
// writes for them shows up in review. Each test regenerates its file with
// the binary, compares the bytes and runs `smock check` on the result. The
// golden files are not Schema fixtures: they are checked here only.

///|
/// Runs `smock import-openapi <args> --output <file>` from the module root,
/// with `<file>` in a temporary directory under the base name of `golden`,
/// and fails unless it writes the bytes of the committed file `golden`. The
/// failure shows the difference and the command that regenerates the file.
/// Then runs `smock check` on the temporary directory, which holds only the
/// new file. Returns how both ended, with the temporary directory written
/// `<dir>`.
async fn regenerated(args : Array[String], golden~ : String) -> String {
  let dir = @fs.tmpdir(prefix="smock-e2e-golden-")
  defer @fs.rmdir(dir, recursive=true)
  let name = golden[golden.rev_find("/").map(i => i + 1).unwrap_or(0):]
  let output = "\{dir}/\{name}"
  let imported = import_openapi([..args, "--output", output], dir~)
  let written = @fs.read_file(output).binary() catch {
    _ => fail("smock import-openapi wrote no file:\n\{imported}")
  }
  let committed = @fs.read_file(golden).binary() catch { _ => b"" }
  if written != committed {
    let (_, difference, problem) = collect_output("git", [
      "diff", "--no-index", "--no-color", "--no-prefix", "--", golden, output,
    ])
    let command = [binary, "import-openapi", ..args, "--output", golden]
    fail(
      (
        $|\{golden} is not what smock import-openapi writes now. If the
        $|change is intended, regenerate the file from the module root, then
        $|review its diff:
        $|  \{command.join(" ")} --overwrite on
        $|
      ) +
      difference.text().replace_all(old=dir, new="<dir>") +
      problem.text(),
    )
  }
  let checked = exit_report(smock_output(["check", dir]))
  "\{imported}smock check: \{checked.replace_all(old=dir, new="<dir>")}"
}

///|
/// smock's own Admin API document, openapi/admin.json: OpenAPI 3.1, with
/// `default` responses and relative references into the Definition-file
/// JSON Schema, so it is imported with `--ref-dir` at the module root,
/// above both. A change to openapi/admin.json, such as specs #73 and #75
/// make, regenerates this golden file in the same change.
async test "smock import-openapi imports the Admin API's own document, with references into the Definition-file Schema, into its golden file, which smock check accepts with no warning" {
  inspect(
    regenerated(
      ["openapi/admin.json", "--mock", "admin", "--ref-dir", "."],
      golden="e2e/golden/admin.yaml",
    ),
    content=(
      #|status 0
      #|wrote <dir>/admin.yaml: 60 Stubs from 15 operations, 0 warnings
      #|smock check: status 0
      #|
    ),
  )
}

///|
/// A public example, the OAI's Petstore: OpenAPI 3.0, with a server path,
/// a concrete and a templated path, `default` responses, a documented
/// response header, and schemas without examples.
///
/// - Source: examples/v3.0/petstore.yaml of
///   https://github.com/OAI/OpenAPI-Specification at the tag 3.1.0 (commit
///   42a9e3d4eddade52363a5c4fac852e80681c2fe5), copied unchanged to
///   e2e/golden/documents/petstore.yaml.
/// - Licence, checked on 2026-10-22: that repository's, the Apache License,
///   Version 2.0, whose text is smock's own LICENSE. The repository has no
///   NOTICE file. The MIT licence that the document's `info` names is the
///   licence of the API it describes, not of the document.
async test "smock import-openapi imports the OAI's Petstore into its golden file, which smock check accepts with no warning" {
  inspect(
    regenerated(
      ["e2e/golden/documents/petstore.yaml", "--mock", "petstore"],
      golden="e2e/golden/petstore.yaml",
    ),
    content=(
      #|status 0
      #|wrote <dir>/petstore.yaml: 6 Stubs from 3 operations, 0 warnings
      #|smock check: status 0
      #|
    ),
  )
}

///|
/// The guide's example, beside the Mockoon one in docs/examples/: a small
/// OpenAPI document written for smock, api/petstore.yaml, and the
/// definitions directory that its import writes, defs/.
let example_dir : String = "docs/examples/from-openapi"

///|
async test "smock import-openapi imports the guide's example into its committed file, which the guide's quick start shows with its document, and smock check accepts with no warning" {
  inspect(
    regenerated(
      ["\{example_dir}/api/petstore.yaml", "--mock", "petstore"],
      golden="\{example_dir}/defs/petstore.yaml",
    ),
    content=(
      #|status 0
      #|wrote <dir>/petstore.yaml: 4 Stubs from 2 operations, 0 warnings
      #|smock check: status 0
      #|
    ),
  )
  let guide = @fs.read_file("docs/importing-openapi.md").text()
  for file in ["api/petstore.yaml", "defs/petstore.yaml"] {
    let text = @fs.read_file("\{example_dir}/\{file}").text()
    if !guide.contains("```yaml\n\{text}```\n") {
      fail("docs/importing-openapi.md does not show \{file} as it is")
    }
  }
}

///|
async test "smock serves the guide's example as its quick start says: the sample, the first example, the example that Smock-Example names, the response that Smock-Status names, and nothing outside the server's path" {
  let _ = with_smock(["--dir", "\{example_dir}/defs", "--port", "0"], smock => {
    let lines = []
    for
      request in [
        ("/v1/pets", []),
        ("/v1/pets/7", []),
        ("/v1/pets/7", [("Smock-Example", "dog")]),
        ("/v1/pets/7", [("Smock-Status", "404")]),
        ("/pets/7", []),
      ] {
      let (path, selectors) = request
      let response = smock.request(
        "GET",
        path,
        headers=[("Host", "localhost"), baggage("quick-start"), ..selectors],
      )
      let response_lines = response.split("\n").collect()
      let status = response_lines[0].trim_end(chars="\r")
      let body = response_lines[response_lines.length() - 1]
      lines.push("\{path}: \{status}: \{body}")
    }
    inspect(
      lines.join("\n"),
      content=(
        #|/v1/pets: HTTP/1.1 200 OK: [{"id":0,"name":"string","species":"cat"}]
        #|/v1/pets/7: HTTP/1.1 200 OK: {"id":7,"name":"Tom","species":"cat"}
        #|/v1/pets/7: HTTP/1.1 200 OK: {"id":7,"name":"Rex","species":"dog"}
        #|/v1/pets/7: HTTP/1.1 404 Not Found: {"message":"Pet not found"}
        #|/pets/7: HTTP/1.1 404 Not Found: {"error":"no Stub matched"}
      ),
    )
    json_inspect(smock.answered_by("quick-start"), content=[
      { "mock": "petstore", "stub": "petstore.listPets.200", "status": 200 },
      { "mock": "petstore", "stub": "petstore.getPet.200", "status": 200 },
      { "mock": "petstore", "stub": "petstore.getPet.200.dog", "status": 200 },
      { "mock": "petstore", "stub": "petstore.getPet.404", "status": 404 },
      { "mock": "petstore", "stub": null, "status": 404 },
    ])
  })
}
