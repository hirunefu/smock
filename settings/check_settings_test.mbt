// The settings of smock check: the definitions directory, its argument, and
// the settings of smock serve that decide how the directory is loaded
// (#320). `--template-env` has its own tests, on the three commands.
// The frame of a refused value, `invalid value "<value>" for <setting>:
// <reason>`, is no document's: the maintainer confirmed on 2026-11-21
// (#329) that it stays as the code has it, with a flag that has no
// variable, or an argument such as <document>, named alone, and a " in
// the value written \".

///|
/// What `smock check <argv>`, with the variables `env`, makes of its
/// settings: `show` of the settings when they are valid, or the message a
/// user sees when they are not.
fn check_shows(
  argv : Array[String],
  env~ : Map[String, String] = {},
  show : (@settings.CheckSettings) -> String,
) -> String {
  let matches = @settings.check_command().parse(argv~, env~) catch {
    err => return "parse: \{err}"
  }
  try @settings.CheckSettings::from_matches(matches) catch {
    err => err.message()
  } noraise {
    settings => show(settings)
  }
}

///|
/// Whether a command takes `value`, given by the flag `flag` and, apart, by
/// its variable `variable`, as smock serve takes it: the same value, or the
/// same message. `read` gives what the command makes of the flag's or the
/// variable's value, and `show` what smock serve does, as
/// `by_flag_and_variable` does. One line per value: `as smock serve` when
/// both agree, and both results when they do not.
fn as_serve_takes(
  flag : String,
  variable : String,
  values : Array[String],
  read : (Array[String], Map[String, String]) -> String,
  show : (@settings.ServeSettings) -> String,
) -> String {
  values
  .map(value => {
    let serve = by_flag_and_variable(flag, variable, value, show)
    let by_flag = read(["\{flag}=\{value}"], {})
    let by_variable = read([], Map([(variable, value)]))
    let command = if by_flag == by_variable {
      "\{value}: \{by_flag}"
    } else {
      "\{value}: \{by_flag}; by \{variable}: \{by_variable}"
    }
    if command == serve {
      "\{value}: as smock serve"
    } else {
      "\{value}: \{command}, where smock serve gives \{serve}"
    }
  })
  .join("\n")
}

///|
test "check: the definitions directory is its argument, and may not be empty" {
  // docs/commands.md, smock check: "smock check defs validates a definitions
  // directory". `InvalidSetting::message` documents the form of the
  // refusal: "invalid value \"\" for <dir>: ...". That the empty value is
  // refused, and the words of its reason, are the code's, which the
  // maintainer decided on 2026-11-18 to keep as they are (#320), as for
  // smock serve's --dir.
  inspect(
    [
      check_shows(["defs"], settings => settings.dir),
      check_shows(["/etc/smock/defs"], settings => settings.dir),
      check_shows([""], settings => settings.dir),
    ].join("\n"),
    content=(
      #|defs
      #|/etc/smock/defs
      #|invalid value "" for <dir>: must not be empty
    ),
  )
}

///|
test "check: it takes --body-file-dir and --header-size-limit, by their flags or variables, as smock serve does" {
  // docs/commands.md, smock check: "It takes --body-file-dir,
  // --template-env and --header-size-limit as smock serve does".
  let read_check = (show : (@settings.CheckSettings) -> String) => {
    (argv : Array[String], env : Map[String, String]) => {
      check_shows([..argv, "defs"], env~, show)
    }
  }
  inspect(
    [
      check_shows(["defs"], settings => {
        "default: \{settings.body_file_dir} \{settings.header_size_limit}"
      }),
      as_serve_takes(
        "--body-file-dir",
        "SMOCK_BODY_FILE_DIR",
        ["bodies/v1", "../files", ""],
        read_check(settings => settings.body_file_dir),
        settings => settings.body_file_dir,
      ),
      as_serve_takes(
        "--header-size-limit",
        "SMOCK_HEADER_SIZE_LIMIT",
        ["1", "1073741824", "0", "1073741825", "16KiB"],
        read_check(settings => settings.header_size_limit.to_string()),
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
