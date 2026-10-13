// Reading the files smock is given by path, such as the TLS certificate
// and key files, the Admin API token file and the sample request of
// `smock render`, with one wording of why a file cannot be read.

///|
/// Why a file could not be read, from the error reading it raised: `no such
/// file`, `permission denied`, `it is not UTF-8 text` for a file read as
/// text, or the OS error otherwise.
pub fn read_failure(err : Error) -> String {
  match err {
    @os_error.OSError(_) as err if err.is_ENOENT() => "no such file"
    @os_error.OSError(_) as err if err.is_EACCES() => "permission denied"
    @utf8.Malformed(_) => "it is not UTF-8 text"
    err => err.to_string()
  }
}

///|
/// The contents of a file, or why it cannot be read, such as
/// `no such file`.
async fn read_file(path : String) -> Result[Bytes, String] {
  // Such as a Secret volume's directory given instead of a file in it.
  let is_dir = try @fs.kind(path) catch {
    _ => false
  } noraise {
    kind => kind is Directory
  }
  if is_dir {
    return Err("is a directory")
  }
  try @fs.read_file(path).binary() catch {
    err => Err(read_failure(err))
  } noraise {
    bytes => Ok(bytes)
  }
}
