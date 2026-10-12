///|
/// The environment variable that can hold the Admin API token itself. It
/// has no flag, so the token never shows in the process list.
let token_variable : String = "SMOCK_ADMIN_TOKEN"

///|
/// Reads the Admin API token, for authentication that is on: from the file
/// `--admin-token-file` names, or else from `SMOCK_ADMIN_TOKEN`, without
/// the whitespace around it. Logs why and returns `None` when smock cannot
/// start: no token is set, both are set, or the file cannot be read or holds
/// no token.
async fn read_admin_token(
  settings : @settings.ServeSettings,
  logger : @log.Logger,
) -> String? {
  let refuse = (reason : String) => {
    logger.error("no Admin API token", fields={ "error": Json::string(reason) })
    None
  }
  let from_variable = match @env.get_env_var(token_variable) {
    Some(token) if token.trim() != "" => Some(token.trim().to_owned())
    _ => None
  }
  match (settings.admin_token_file, from_variable) {
    (None, None) =>
      refuse(
        "Admin API authentication is on, but no token is set: set --admin-token-file (SMOCK_ADMIN_TOKEN_FILE) or \{token_variable}, or turn authentication off with --admin-auth off",
      )
    (Some(_), Some(_)) =>
      refuse(
        "both --admin-token-file (SMOCK_ADMIN_TOKEN_FILE) and \{token_variable} are set; set only one",
      )
    (None, Some(token)) => Some(token)
    (Some(file), None) => {
      let text = @fs.read_file(file).text() catch {
        err => {
          let reason = match err {
            @os_error.OSError(_) as err if err.is_ENOENT() => "no such file"
            @os_error.OSError(_) as err if err.is_EACCES() =>
              "permission denied"
            @os_error.OSError(_) => err.to_string()
            _ => "it is not UTF-8 text"
          }
          return refuse(
            "cannot read the token file \{file.escape()}: \{reason}",
          )
        }
      }
      match text.trim() {
        "" => refuse("the token file \{file.escape()} is empty")
        token => Some(token.to_owned())
      }
    }
  }
}
