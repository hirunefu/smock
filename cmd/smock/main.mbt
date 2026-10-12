///|
/// Ends the process with `code`, through libc's `exit` (no C source).
/// Usage errors exit with 2.
extern "c" fn exit(code : Int) = "exit"

///|
fn main {
  let cli = @argparse.Command(
    "smock",
    about="A mock server for HTTP/1.1, HTTPS and Server-Sent Events.",
    version=@buildinfo.current().version_line(),
    arg_required_else_help=true,
  )
  // `--help` and `--version` print and exit 0 inside `parse`.
  try cli.parse() catch {
    err => {
      eprintln(err.to_string())
      exit(2)
    }
  } noraise {
    _ => ()
  }
}
