// The settings of smock render: the Stub ID, its argument; the definitions
// directory and the settings of smock serve that decide how the directory
// is loaded; and the sample request, the time, the seed and the response,
// flags of its own without variables (#320). `--template-env` has its own
// tests, on the three commands. A flag without a variable is named alone in
// a refusal, in the form `InvalidSetting::message` documents.
// The frame of a refused value, `invalid value "<value>" for <setting>:
// <reason>`, is no document's: the maintainer confirmed on 2026-11-21
// (#329) that it stays as the code has it, with a flag that has no
// variable, or an argument such as <document>, named alone, and a " in
// the value written \".

///|
/// What `smock render <argv>`, with the variables `env`, makes of its
/// settings, after the Stub ID `get-user`, `--dir defs` and `--request
/// sample.json` unless `argv` gives them or `without` names them: `show` of
/// the settings when they are valid, or the message a user sees when they
/// are not.
fn render_shows(
  argv : Array[String],
  env~ : Map[String, String] = {},
  without~ : Array[String] = [],
  show : (@settings.RenderSettings) -> String,
) -> String {
  let given = (flag : String) => {
    without.contains(flag) ||
    argv.iter().any(arg => arg == flag || arg.has_prefix("\{flag}="))
  }
  let argv = [
    "get-user",
    ..if given("--dir") || env.contains("SMOCK_DIR") {
      []
    } else {
      ["--dir", "defs"]
    },
    ..if given("--request") {
      []
    } else {
      ["--request", "sample.json"]
    },
    ..argv,
  ]
  let matches = @settings.render_command().parse(argv~, env~) catch {
    err => return "parse: \{err}"
  }
  try @settings.RenderSettings::from_matches(matches) catch {
    err => err.message()
  } noraise {
    settings => show(settings)
  }
}

///|
test "render: the Stub ID is its argument, and --dir, by its flag or SMOCK_DIR, and --request name the definitions directory and the sample request, neither of them empty" {
  // docs/commands.md, smock render: "smock render --dir defs get-user
  // --request sample.json shows what a Stub returns for a sample request".
  // docs/running.md, Settings: SMOCK_DIR is --dir's variable, and smock
  // render reads the directory "as smock serve does". A path names a file
  // or a directory, and no file has the empty name.
  let shown = (settings : @settings.RenderSettings) => {
    "\{settings.stub} \{settings.dir} \{settings.request_file}"
  }
  inspect(
    [
      render_shows([], shown),
      render_shows(["--dir", "/etc/smock/defs"], shown),
      render_shows([], env={ "SMOCK_DIR": "/etc/smock/defs" }, shown),
      render_shows(["--dir", "defs"], env={ "SMOCK_DIR": "elsewhere" }, shown),
      render_shows(["--dir="], shown),
      render_shows([], env={ "SMOCK_DIR": "" }, shown),
      render_shows(["--request="], shown),
    ].join("\n"),
    content=(
      #|get-user defs sample.json
      #|get-user /etc/smock/defs sample.json
      #|get-user /etc/smock/defs sample.json
      #|get-user defs sample.json
      #|invalid value "" for --dir (SMOCK_DIR): must not be empty
      #|invalid value "" for --dir (SMOCK_DIR): must not be empty
      #|invalid value "" for --request: must not be empty
    ),
  )
}

///|
test "render: without --dir or SMOCK_DIR, or without --request, the command line is refused as missing a required argument" {
  // smock render --help: "Usage: smock render --dir <dir> --request
  // <request> [options] <stub-id>", so both are required; SMOCK_DIR is
  // --dir's variable (docs/running.md, Settings), which the test above
  // gives alone. The words are the command-line parser's, which
  // e2e/render_test.mbt "smock render needs the definitions directory, a
  // Stub ID and a sample request" pins too: the maintainer decided on
  // 2026-11-18 that the words of usage errors stay as they are (#320). The
  // usage and the help that follow the first line are the help's own test.
  // These words are moonbitlang/core's argparse's, not smock's: the
  // maintainer confirmed on 2026-11-21 (#329) that the decision of
  // 2026-11-18 covers them, as the reasons of usage errors that no document
  // words.
  let shown = (settings : @settings.RenderSettings) => {
    "\{settings.dir} \{settings.request_file}"
  }
  let first_line = (text : String) => text.split("\n").next().unwrap_or("")
  inspect(
    [
      first_line(render_shows([], without=["--dir"], shown)),
      first_line(render_shows([], without=["--request"], shown)),
    ].join("\n"),
    content=(
      #|parse: error: the following required argument was not provided: 'dir'
      #|parse: error: the following required argument was not provided: 'request'
    ),
  )
}

///|
test "render: --time takes an RFC 3339 date-time, in milliseconds since the Unix epoch, and refuses any other value" {
  // docs/commands.md, smock render: "--time (RFC 3339) and --seed fix the
  // clock and the random source of the rendering", and without it the
  // rendering is "now" (its help: "Default: now"). The milliseconds are
  // Python's datetime(2026, 10, 12, 14, 30, 5, tzinfo=timezone.utc)
  // .timestamp() * 1000. @log.parse_time reads the date-time, as its
  // documentation says; the template and Journal tests that use it check
  // more of its forms.
  let time = (settings : @settings.RenderSettings) => {
    match settings.time {
      Some(time) => time.to_string()
      None => "now"
    }
  }
  inspect(
    [
      render_shows([], time),
      render_shows(["--time", "2026-10-12T14:30:05Z"], time),
      render_shows(["--time", "2026-10-12T16:30:05+02:00"], time),
      render_shows(["--time", "2026-10-12 14:30:05"], time),
      render_shows(["--time", "1791815405000"], time),
      render_shows(["--time="], time),
    ].join("\n"),
    content=(
      #|now
      #|1791815405000
      #|1791815405000
      #|invalid value "2026-10-12 14:30:05" for --time: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
      #|invalid value "1791815405000" for --time: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
      #|invalid value "" for --time: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
    ),
  )
}

///|
test "render: --seed takes 0 and 2^53 - 1, and refuses -1, 2^53 and a value that is not a decimal integer" {
  // docs/definition-files/templates.md, Rendering a template: --seed gives
  // what "a Stub with fault.seed: S" gets, and a Stub's seed is "from 0 to
  // 9007199254740991" (docs/definition-files/faults.md, Seeds). Without
  // it, the rendering uses the Stub's seed or a fresh one. A value with
  // leading zeros is the integer it writes (#426): 00000000000000007,
  // seventeen characters, is 7.
  let seed = (settings : @settings.RenderSettings) => {
    match settings.seed {
      Some(seed) => seed.to_string()
      None => "none"
    }
  }
  inspect(
    [
      render_shows([], seed),
      render_shows(["--seed=0"], seed),
      render_shows(["--seed=9007199254740991"], seed),
      render_shows(["--seed=-1"], seed),
      render_shows(["--seed=9007199254740992"], seed),
      render_shows(["--seed=0x2a"], seed),
      render_shows(["--seed=00000000000000007"], seed),
    ].join("\n"),
    content=(
      #|none
      #|0
      #|9007199254740991
      #|invalid value "-1" for --seed: must be an integer from 0 to 9007199254740991
      #|invalid value "9007199254740992" for --seed: must be an integer from 0 to 9007199254740991
      #|invalid value "0x2a" for --seed: must be an integer from 0 to 9007199254740991
      #|7
    ),
  )
}

///|
test "render: --response takes 0 and 99, and refuses -1, 100 and a value that is not a decimal integer" {
  // docs/definition-files/templates.md, Rendering a template: --response
  // renders "the response at index i instead, from 0", and "a value that
  // is not an integer from 0 to 99 is refused before rendering: ... a usage
  // error with status 2". Without it, the seed picks the response. A value
  // with leading zeros is the integer it writes (#426): 007 is 7, and 0100
  // is 100, which is refused.
  let response = (settings : @settings.RenderSettings) => {
    match settings.response_index {
      Some(index) => index.to_string()
      None => "the seed's"
    }
  }
  inspect(
    [
      render_shows([], response),
      render_shows(["--response=0"], response),
      render_shows(["--response=99"], response),
      render_shows(["--response=-1"], response),
      render_shows(["--response=100"], response),
      render_shows(["--response=x"], response),
      render_shows(["--response=007"], response),
      render_shows(["--response=0100"], response),
    ].join("\n"),
    content=(
      #|the seed's
      #|0
      #|99
      #|invalid value "-1" for --response: must be an integer from 0 to 99
      #|invalid value "100" for --response: must be an integer from 0 to 99
      #|invalid value "x" for --response: must be an integer from 0 to 99
      #|7
      #|invalid value "0100" for --response: must be an integer from 0 to 99
    ),
  )
}

///|
test "render: it takes --body-file-dir and --header-size-limit, by their flags or variables, as smock serve does" {
  // docs/commands.md, smock render: "It takes --body-file-dir,
  // --template-env and --header-size-limit as smock serve does".
  let read_render = (show : (@settings.RenderSettings) -> String) => {
    (argv : Array[String], env : Map[String, String]) => {
      render_shows(argv, env~, show)
    }
  }
  inspect(
    [
      render_shows([], settings => {
        "default: \{settings.body_file_dir} \{settings.header_size_limit}"
      }),
      as_serve_takes(
        "--body-file-dir",
        "SMOCK_BODY_FILE_DIR",
        ["bodies/v1", "../files", ""],
        read_render(settings => settings.body_file_dir),
        settings => settings.body_file_dir,
      ),
      as_serve_takes(
        "--header-size-limit",
        "SMOCK_HEADER_SIZE_LIMIT",
        ["1", "1073741824", "0", "1073741825", "16KiB"],
        read_render(settings => settings.header_size_limit.to_string()),
        settings => settings.header_size_limit.to_string(),
      ),
    ].join("\n"),
    content=(
      #|default: files 16384
      #|bodies/v1: as smock serve
      #|../files: as smock serve
      #|: as smock serve
      #|1: as smock serve
      #|1073741824: as smock serve
      #|0: as smock serve
      #|1073741825: as smock serve
      #|16KiB: as smock serve
    ),
  )
}
