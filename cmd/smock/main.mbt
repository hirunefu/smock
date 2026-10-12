///|
/// Ends the process with `code`, through libc's `exit` (no C source).
/// Usage errors, including invalid settings, exit with 2.
extern "c" fn exit(code : Int) = "exit"

///|
async fn main {
  let cli = @argparse.Command(
    "smock",
    about="A mock server for HTTP/1.1, HTTPS and Server-Sent Events.",
    version=@buildinfo.current().version_line(),
    arg_required_else_help=true,
    subcommands=[@settings.serve_command(), @settings.check_command()],
  )
  // `--help` and `--version` print and exit 0 inside `parse`.
  let matches = cli.parse(env=@env.get_env_vars()) catch {
    err => {
      eprintln(err.to_string())
      exit(2)
      return
    }
  }
  match matches.subcommand {
    Some(("serve", matches)) => {
      let settings = @settings.ServeSettings::from_matches(matches) catch {
        err => {
          eprintln("smock serve: \{err.message()}")
          exit(2)
          return
        }
      }
      let logger = match settings.log_format {
        Json =>
          @log.Logger(write_line=line => eprintln(line), now=() => @async.now())
      }
      let admin_auth = if settings.admin_auth { "on" } else { "off" }
      @buildinfo.current().log_startup(logger, fields={
        "adminAuth": Json::string(admin_auth),
      })
      exit(@server.serve(settings, logger))
    }
    Some(("check", matches)) => {
      let settings = @settings.CheckSettings::from_matches(matches) catch {
        err => {
          eprintln("smock check: \{err.message()}")
          exit(2)
          return
        }
      }
      exit(check(settings))
    }
    _ => ()
  }
}

///|
/// Runs `smock check`: loads the definitions directory as `smock serve`
/// does and prints every problem to stdout, one per line, or, when the set
/// is valid, every warning, such as a Stub that can never match. Returns the
/// exit status: 0 when the definition set is valid, with or without
/// warnings, 1 when it is not.
async fn check(settings : @settings.CheckSettings) -> Int {
  match @defdir.load(Some(settings.dir), body_file_dir=settings.body_file_dir) {
    Ok(snapshot) => {
      for warning in snapshot.warnings() {
        println(warning.to_string())
      }
      0
    }
    Err(diagnostics) => {
      for diagnostic in diagnostics {
        println(diagnostic.to_string())
      }
      1
    }
  }
}
