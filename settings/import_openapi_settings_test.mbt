// The settings of smock import-openapi: the OpenAPI document, its argument,
// and flags of its own without variables, since "the flags belong to one
// run, so none has an SMOCK_ variable" (docs/commands.md) (#320). A flag is
// named alone in a refusal, and the argument by its name, in the forms
// `InvalidSetting::message` documents. The documents say which values each
// takes, but not the words of a refusal's reason: those are the code's,
// and the maintainer, who decided on 2026-11-18 that they stay as they are
// (#320), is their source.

///|
/// What `smock import-openapi <argv>` makes of its settings, after the
/// document `api/openapi.yaml`, `--mock petstore` and `--output
/// defs/petstore.yaml` unless `argv` gives them or `without` names them
/// (`document` gives the document): `show` of the settings when they are
/// valid, or the message a user sees when they are not.
fn import_shows(
  argv : Array[String],
  document~ : String = "api/openapi.yaml",
  without~ : Array[String] = [],
  show : (@settings.ImportOpenapiSettings) -> String,
) -> String {
  let given = (flag : String) => {
    without.contains(flag) ||
    argv.iter().any(arg => arg == flag || arg.has_prefix("\{flag}="))
  }
  let argv = [
    document,
    ..if given("--mock") {
      []
    } else {
      ["--mock", "petstore"]
    },
    ..if given("--output") {
      []
    } else {
      ["--output", "defs/petstore.yaml"]
    },
    ..argv,
  ]
  let matches = @settings.import_openapi_command().parse(argv~, env={}) catch {
    err => return "parse: \{err}"
  }
  try @settings.ImportOpenapiSettings::from_matches(matches) catch {
    err => err.message()
  } noraise {
    settings => show(settings)
  }
}

///|
test "import-openapi: the document is its argument, a file whose name ends in .json, .yaml or .yml" {
  // docs/importing-openapi.md, the arguments: "<document>: the OpenAPI
  // document, a file whose name ends in .json, .yaml or .yml".
  let named = (settings : @settings.ImportOpenapiSettings) => settings.document
  inspect(
    [
      import_shows([], named),
      import_shows([], document="openapi.json", named),
      import_shows([], document="/srv/api/petstore.yml", named),
      import_shows([], document="api.txt", named),
      import_shows([], document="api.JSON", named),
      import_shows([], document="openapi", named),
      import_shows([], document="", named),
    ].join("\n"),
    content=(
      #|api/openapi.yaml
      #|openapi.json
      #|/srv/api/petstore.yml
      #|invalid value "api.txt" for <document>: must name a .json, .yaml or .yml file
      #|invalid value "api.JSON" for <document>: must name a .json, .yaml or .yml file
      #|invalid value "openapi" for <document>: must name a .json, .yaml or .yml file
      #|invalid value "" for <document>: must name a .json, .yaml or .yml file
    ),
  )
}

///|
test "import-openapi: --mock names the Mock, and may not be empty" {
  // docs/commands.md, smock import-openapi: --mock is "Required: the name
  // of the Mock the file declares". A Mock's name is "a non-empty name"
  // (schema/v1/definitions.json, `$defs/name`).
  let mock = (settings : @settings.ImportOpenapiSettings) => settings.mock
  inspect(
    [
      import_shows([], mock),
      import_shows(["--mock", "users"], mock),
      import_shows(["--mock="], mock),
    ].join("\n"),
    content=(
      #|petstore
      #|users
      #|invalid value "" for --mock: must not be empty
    ),
  )
}

///|
test "import-openapi: --output names a .json, .yaml or .yml file, whose own name does not start with ." {
  // docs/importing-openapi.md, the arguments: "--output <file>: the
  // Definition file to write. Its name picks the format: .yaml or .yml
  // writes YAML ... and .json writes JSON ... A name that starts with . is
  // refused, since smock skips such files." Only the file's own name
  // counts: the directories on its path are not Definition files.
  let output = (settings : @settings.ImportOpenapiSettings) => settings.output
  inspect(
    [
      import_shows([], output),
      import_shows(["--output", "petstore.json"], output),
      import_shows(["--output", "./defs/petstore.yml"], output),
      import_shows(["--output", "m.txt"], output),
      import_shows(["--output", "m.YAML"], output),
      import_shows(["--output", "defs/.m.json"], output),
      import_shows(["--output", ".m.yaml"], output),
      import_shows(["--output="], output),
    ].join("\n"),
    content=(
      #|defs/petstore.yaml
      #|petstore.json
      #|./defs/petstore.yml
      #|invalid value "m.txt" for --output: must name a .json, .yaml or .yml file
      #|invalid value "m.YAML" for --output: must name a .json, .yaml or .yml file
      #|invalid value "defs/.m.json" for --output: must not name a file that starts with ., which smock skips
      #|invalid value ".m.yaml" for --output: must not name a file that starts with ., which smock skips
      #|invalid value "" for --output: must name a .json, .yaml or .yml file
    ),
  )
}

///|
test "import-openapi: without --mock or without --output, the command line is refused as missing a required argument" {
  // docs/commands.md, smock import-openapi: --mock and --output are each
  // "Required", and the command exits with "2 for a usage error". The
  // words are the command-line parser's, which e2e/import_openapi_test.mbt
  // "smock import-openapi rejects bad arguments as usage errors, on stderr
  // with exit status 2" pins too: the maintainer decided on 2026-11-18 that
  // the words of usage errors stay as they are (#320). The usage and the
  // help that follow the first line are the help's own test.
  let mock = (settings : @settings.ImportOpenapiSettings) => settings.mock
  let first_line = (text : String) => text.split("\n").next().unwrap_or("")
  inspect(
    [
      first_line(import_shows([], without=["--mock"], mock)),
      first_line(import_shows([], without=["--output"], mock)),
    ].join("\n"),
    content=(
      #|parse: error: the following required argument was not provided: 'mock'
      #|parse: error: the following required argument was not provided: 'output'
    ),
  )
}

///|
test "import-openapi: --declare-mock, on by default, and --overwrite, off by default, take on and off, and refuse any other value" {
  // docs/commands.md, smock import-openapi: "--declare-mock on|off: on by
  // default" and "--overwrite on|off: off by default".
  let flags = (settings : @settings.ImportOpenapiSettings) => {
    "\{settings.declare_mock} \{settings.overwrite}"
  }
  inspect(
    [
      import_shows([], flags),
      import_shows(["--declare-mock", "off", "--overwrite", "on"], flags),
      import_shows(["--declare-mock", "on", "--overwrite", "off"], flags),
      import_shows(["--declare-mock", "yes"], flags),
      import_shows(["--declare-mock", "OFF"], flags),
      import_shows(["--overwrite", "true"], flags),
      import_shows(["--overwrite="], flags),
    ].join("\n"),
    content=(
      #|true false
      #|false true
      #|true false
      #|invalid value "yes" for --declare-mock: must be on or off
      #|invalid value "OFF" for --declare-mock: must be on or off
      #|invalid value "true" for --overwrite: must be on or off
      #|invalid value "" for --overwrite: must be on or off
    ),
  )
}

///|
test "import-openapi: --hosts lists Hosts a Definition file can declare, none the same as another, and only for a Mock the file declares" {
  // docs/importing-openapi.md, The Mock and its Hosts: "Each Host must be
  // one a Definition file can declare, as smock check checks it ... A Host
  // that is not one, or that is the same as another once compared as smock
  // compares Hosts (in lower case, without the port and a trailing dot), is
  // a usage error", and with --declare-mock off, "--hosts is refused".
  // --hosts is "None by default" (docs/commands.md), and `--hosts ""` means
  // no Hosts for a declared Mock (`ImportOpenapiSettings::from_matches`'s
  // helper, `hosts_value`, documents it). The reason a Host cannot be
  // declared is the definitions package's, which its own tests assert.
  let hosts = (settings : @settings.ImportOpenapiSettings) => {
    "[\{settings.hosts.join(",")}]"
  }
  inspect(
    [
      import_shows([], hosts),
      import_shows(["--hosts", "petstore.test,pets.internal:8080"], hosts),
      import_shows(["--hosts", "[::1]:8080"], hosts),
      import_shows(["--hosts="], hosts),
      import_shows(["--hosts", ":8080"], hosts),
      import_shows(["--hosts", "*.example.com"], hosts),
      import_shows(["--hosts", "a.test,,b.test"], hosts),
      import_shows(["--hosts", "pets.test,b.test,PETS.test.:8080"], hosts),
      // docs/definition-files.md, Hosts and the Default Mock: "An IPv6
      // address without a port may also be written without brackets, and
      // is then the same Host as the bracketed one" (the maintainer,
      // 2026-11-21, #329).
      import_shows(["--hosts", "[::1],::1"], hosts),
      import_shows(["--declare-mock", "off"], hosts),
      import_shows(["--declare-mock", "off", "--hosts", "a.test"], hosts),
      import_shows(["--declare-mock", "off", "--hosts="], hosts),
    ].join("\n"),
    content=(
      #|[]
      #|[petstore.test,pets.internal:8080]
      #|[[::1]:8080]
      #|[]
      #|invalid value ":8080" for --hosts: ":8080" must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|invalid value "*.example.com" for --hosts: "*.example.com" must be an exact name: Hosts have no wildcards
      #|invalid value "a.test,,b.test" for --hosts: "" must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|invalid value "pets.test,b.test,PETS.test.:8080" for --hosts: "PETS.test.:8080" is the same Host as "pets.test": Hosts are compared in lower case, without the port and a trailing dot
      #|invalid value "[::1],::1" for --hosts: "::1" is the same Host as "[::1]": Hosts are compared in lower case, without the port and a trailing dot
      #|[]
      #|invalid value "a.test" for --hosts: must not be given with --declare-mock off: give the Hosts where the Mock is declared
      #|invalid value "" for --hosts: must not be given with --declare-mock off: give the Hosts where the Mock is declared
    ),
  )
}

///|
test "import-openapi: --base-path starts with / and holds no ? or #" {
  // docs/importing-openapi.md, the arguments: "--base-path <path>: a path
  // to put in front of every path ... / means no prefix. It must start
  // with / and hold no ? or #." Without it, the servers' paths are used.
  let base_path = (settings : @settings.ImportOpenapiSettings) => {
    match settings.base_path {
      Some(path) => path
      None => "the servers'"
    }
  }
  inspect(
    [
      import_shows([], base_path),
      import_shows(["--base-path", "/mock/petstore"], base_path),
      import_shows(["--base-path", "/"], base_path),
      import_shows(["--base-path", "mock/petstore"], base_path),
      import_shows(["--base-path="], base_path),
      import_shows(["--base-path", "/v1?x=1"], base_path),
      import_shows(["--base-path", "/v1#top"], base_path),
    ].join("\n"),
    content=(
      #|the servers'
      #|/mock/petstore
      #|/
      #|invalid value "mock/petstore" for --base-path: must start with /
      #|invalid value "" for --base-path: must start with /
      #|invalid value "/v1?x=1" for --base-path: must not hold ? or #: a query or a fragment is not part of a path
      #|invalid value "/v1#top" for --base-path: must not hold ? or #: a query or a fragment is not part of a path
    ),
  )
}

///|
test "import-openapi: --ref-dir names a directory, and may not be empty" {
  // docs/importing-openapi.md, the arguments: "--ref-dir <dir>: the
  // directory that references to other files are followed in. It is the
  // document's own directory by default". A path names a directory, and no
  // directory has the empty name. That --ref-dir names a directory is
  // checked by the CLI, which reads the file system (see the tests of
  // `document_name_under`).
  let ref_dir = (settings : @settings.ImportOpenapiSettings) => {
    match settings.ref_dir {
      Some(dir) => dir
      None => "the document's"
    }
  }
  inspect(
    [
      import_shows([], ref_dir),
      import_shows(["--ref-dir", "."], ref_dir),
      import_shows(["--ref-dir="], ref_dir),
    ].join("\n"),
    content=(
      #|the document's
      #|.
      #|invalid value "" for --ref-dir: must not be empty
    ),
  )
}

///|
/// The settings of `smock import-openapi <document> --mock petstore
/// --output defs/petstore.yaml`, with `--ref-dir <ref_dir>` when it is
/// given.
fn import_settings(
  document : String,
  ref_dir? : String,
) -> @settings.ImportOpenapiSettings raise {
  let argv = [document, "--mock", "petstore", "--output", "defs/petstore.yaml"]
  if ref_dir is Some(dir) {
    argv.push("--ref-dir=\{dir}")
  }
  let matches = @settings.import_openapi_command().parse(argv~, env={})
  @settings.ImportOpenapiSettings::from_matches(matches)
}

///|
test "import-openapi: problems in other files are named under --ref-dir as given, or else under the document's directory as given" {
  // docs/openapi/references-and-yaml.md, References to other files: "A
  // problem in another file names it as --ref-dir, as given, joined with
  // its path under --ref-dir, such as ./api/responses/ok.yaml above.
  // Without --ref-dir, the directory part of the document's path, as given,
  // takes its place: api/responses/ok.yaml."
  // The guide does not say whether that part keeps its last / (api/ and
  // /srv/specs/api/ here), or what it is for a bare file name (empty here):
  // the importer joins it with a / unless it is empty or ends in one, so
  // these are the contract between the settings and the importer, which
  // the maintainer confirmed on 2026-11-21 (#329).
  let shown = (settings : @settings.ImportOpenapiSettings) => {
    "\{settings.document}: \{settings.ref_dir_path()} \{settings.document_directory().escape()}"
  }
  inspect(
    [
      shown(import_settings("api/openapi.yaml")),
      shown(import_settings("api/openapi.yaml", ref_dir=".")),
      shown(import_settings("openapi.yaml")),
      shown(
        import_settings("/srv/specs/api/openapi.json", ref_dir="/srv/specs"),
      ),
      // The guide's rule at the root: the directory part of /openapi.yaml
      // is /, so a problem in responses/ok.yaml is named
      // /responses/ok.yaml (the maintainer, 2026-11-21, #329).
      shown(import_settings("/openapi.yaml")),
    ].join("\n"),
    content=(
      #|api/openapi.yaml: api/ "api/"
      #|api/openapi.yaml: . "api/"
      #|openapi.yaml:  ""
      #|/srv/specs/api/openapi.json: /srv/specs "/srv/specs/api/"
      #|/openapi.yaml: / "/"
    ),
  )
}

///|
test "import-openapi: the document's name under --ref-dir comes from the real paths, and a document outside --ref-dir, or a --ref-dir that is no directory, is a usage error" {
  // docs/openapi/references-and-yaml.md, References to other files: files
  // are read only under --ref-dir, "the document's own directory by
  // default, and the document must lie under it"; a reference's path "is
  // resolved against the directory of the document that names it"; and "a
  // document outside --ref-dir, or a --ref-dir that is not a directory, is
  // a usage error". `document_name_under` documents its arguments: the real
  // paths of --ref-dir, `None` when it names no directory, and of the
  // document's directory, `None` when it cannot be resolved, which the CLI
  // finds on the file system.
  let under = (
    settings : @settings.ImportOpenapiSettings,
    ref_dir : String?,
    document_dir : String?,
  ) => {
    try settings.document_name_under(ref_dir~, document_dir~) catch {
      err => err.message()
    } noraise {
      name => name
    }
  }
  inspect(
    [
      // Without --ref-dir, the document's own directory.
      under(
        import_settings("api/openapi.yaml"),
        Some("/work/api"),
        Some("/work/api"),
      ),
      under(
        import_settings("api/openapi.yaml", ref_dir="."),
        Some("/work"),
        Some("/work/api"),
      ),
      under(
        import_settings("v1/openapi.yaml", ref_dir="."),
        Some("/work"),
        Some("/work/api/v1"),
      ),
      under(
        import_settings("api/openapi.yaml", ref_dir="api"),
        Some("/work/api"),
        Some("/work/api"),
      ),
      // The root directory, whose real path ends in /.
      under(
        import_settings("/work/api/openapi.yaml", ref_dir="/"),
        Some("/"),
        Some("/work/api"),
      ),
      // A document directory that cannot be resolved: reading the document
      // fails then too.
      under(
        import_settings("gone/openapi.yaml", ref_dir="."),
        Some("/work"),
        None,
      ),
      under(
        import_settings("api/openapi.yaml", ref_dir="missing"),
        None,
        Some("/work/api"),
      ),
      under(
        import_settings("api/openapi.yaml", ref_dir="shared"),
        Some("/work/shared"),
        Some("/work/api"),
      ),
      // A directory whose name starts with --ref-dir's is not under it.
      under(
        import_settings("api2/openapi.yaml", ref_dir="api"),
        Some("/work/api"),
        Some("/work/api2"),
      ),
      under(
        import_settings("openapi.yaml", ref_dir="api"),
        Some("/work/api"),
        Some("/work"),
      ),
    ].join("\n"),
    content=(
      #|openapi.yaml
      #|api/openapi.yaml
      #|api/v1/openapi.yaml
      #|openapi.yaml
      #|work/api/openapi.yaml
      #|openapi.yaml
      #|invalid value "missing" for --ref-dir: must name a directory
      #|invalid value "api/openapi.yaml" for <document>: must lie under --ref-dir "shared"
      #|invalid value "api2/openapi.yaml" for <document>: must lie under --ref-dir "api"
      #|invalid value "openapi.yaml" for <document>: must lie under --ref-dir "api"
    ),
  )
}

///|
test "import-openapi: a real path lies under a directory when it is below it, not when it is the directory or a sibling whose name starts the same" {
  // `is_under` documents it: "Whether the real path real lies below the
  // directory whose real path is directory ... The directory itself does
  // not." docs/openapi/references-and-yaml.md: a file "that a symlink
  // leads outside --ref-dir" is an error, which the CLI decides with it.
  inspect(
    [
      @settings.is_under("/work/api/openapi.yaml", "/work"),
      @settings.is_under("/work/api", "/work/"),
      @settings.is_under("/work", "/"),
      @settings.is_under("/work", "/work"),
      @settings.is_under("/work2/openapi.yaml", "/work"),
      @settings.is_under("/etc/passwd", "/work"),
    ]
    .map(Bool::to_string)
    .join(" "),
    content="true true true false false false",
  )
}
