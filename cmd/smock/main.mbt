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
    subcommands=[@settings.serve_command()],
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
      @buildinfo.current().log_startup(logger)
      exit(@server.serve(settings, logger))
    }
    _ => ()
  }
}
