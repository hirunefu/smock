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
    subcommands=[
      @settings.serve_command(),
      @settings.check_command(),
      @settings.render_command(),
    ],
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
    Some(("render", matches)) => {
      let settings = @settings.RenderSettings::from_matches(matches) catch {
        err => {
          eprintln("smock render: \{err.message()}")
          exit(2)
          return
        }
      }
      exit(render(settings))
    }
    _ => ()
  }
}

///|
/// Runs `smock render`: loads the definitions directory as `smock serve`
/// does, reads the sample request, renders the named Stub's response for it
/// and prints the rendering to stdout as JSON, in the form of the Admin
/// render operation's result without its warnings. Returns the exit status:
/// 0 when it rendered, 1 when the definition set is invalid, with the
/// messages `smock check` prints, when the sample request cannot be read or
/// is not valid, or when no Stub has the ID. Every problem goes to stderr.
async fn render(settings : @settings.RenderSettings) -> Int {
  let snapshot = match
    @defdir.load(Some(settings.dir), body_file_dir=settings.body_file_dir) {
    Ok(snapshot) => snapshot
    Err(diagnostics) => {
      for diagnostic in diagnostics {
        eprintln(diagnostic.to_string())
      }
      return 1
    }
  }
  let file = settings.request_file
  let text = @fs.read_file(file).text() catch {
    err => {
      let reason = match err {
        @os_error.OSError(_) as err if err.is_ENOENT() => "no such file"
        @os_error.OSError(_) as err if err.is_EACCES() => "permission denied"
        @os_error.OSError(_) => err.to_string()
        _ => "it is not UTF-8 text"
      }
      eprintln(
        "smock render: cannot read the sample request \{file}: \{reason}",
      )
      return 1
    }
  }
  let json = @json.parse(text) catch {
    err => {
      eprintln(
        "smock render: the sample request \{file} is not valid JSON: \{err}",
      )
      return 1
    }
  }
  let sample = @engine.SampleRequest::from_json(json) catch {
    err => {
      eprintln(
        "smock render: the sample request \{file} is not valid: \{err.message()}",
      )
      return 1
    }
  }
  let seed = match settings.seed {
    Some(seed) => seed
    None => @settings.random_seed()
  }
  let rendering = @engine.Engine(snapshot).render(
    settings.stub,
    sample,
    now=settings.time.unwrap_or(@async.now()),
    rand=@prng.Generator(seed),
  ) catch {
    err => {
      eprintln("smock render: \{err.message()}")
      return 1
    }
  }
  println(rendering.to_json().stringify(indent=2))
  0
}

///|
/// Runs `smock check`: loads the definitions directory as `smock serve`
/// does and prints every problem to stdout, one per line, or, when the set
/// is valid, every warning, such as a Stub that can never match. Returns the
/// exit status: 0 when the definition set is valid, with or without
/// warnings, 1 when it is not.
///
/// A missing directory is an empty definition set, which is valid, as for
/// `smock serve`. Since a mistyped path then passes too, `check` says on
/// stderr that the directory does not exist.
async fn check(settings : @settings.CheckSettings) -> Int {
  let dir = settings.dir
  // When the directory cannot be looked at, loading it reports why.
  if !(@fs.exists(dir) catch { _ => true }) {
    eprintln(
      "smock check: the definitions directory \{dir} does not exist, so it is read as an empty definition set",
    )
  }
  match @defdir.load(Some(dir), body_file_dir=settings.body_file_dir) {
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
