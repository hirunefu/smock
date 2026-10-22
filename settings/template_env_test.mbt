// The `--template-env` setting of `smock serve`, `smock check` and
// `smock render`: the environment variables templates may read.

///|
/// The names that `smock <command> <argv>` with the variables `env` lists
/// in `--template-env`, comma-separated, or the message of the usage error.
fn listed(
  command : String,
  argv : Array[String],
  env? : Map[String, String] = {},
) -> String raise {
  let names = match command {
    "serve" => {
      let matches = @settings.serve_command().parse(argv~, env~)
      template_env(() => {
        @settings.ServeSettings::from_matches(matches).template_env
      })
    }
    "check" => {
      let matches = @settings.check_command().parse(argv=[..argv, "defs"], env~)
      template_env(() => {
        @settings.CheckSettings::from_matches(matches).template_env
      })
    }
    _ => {
      let matches = @settings.render_command().parse(
        argv=[..argv, "--dir", "defs", "--request", "r.json", "stub"],
        env~,
      )
      template_env(() => {
        @settings.RenderSettings::from_matches(matches).template_env
      })
    }
  }
  match names {
    Ok(names) => "[\{names.join(",")}]"
    Err(message) => message
  }
}

///|
/// The names `read` gives, or the message of the setting it finds invalid.
fn template_env(
  read : () -> Array[String] raise @settings.InvalidSetting,
) -> Result[Array[String], String] {
  try read() catch {
    err => Err(err.message())
  } noraise {
    names => Ok(names)
  }
}

///|
test "--template-env lists names separated by commas, on serve, check and render, with SMOCK_TEMPLATE_ENV; the flag wins" {
  let out = []
  for command in ["serve", "check", "render"] {
    out.push(
      [
        listed(command, []),
        listed(command, ["--template-env", "REGION"]),
        listed(command, ["--template-env", "REGION,API_BASE,_x1"]),
        listed(command, [], env={ "SMOCK_TEMPLATE_ENV": "REGION,ZONE" }),
        listed(command, ["--template-env", "REGION"], env={
          "SMOCK_TEMPLATE_ENV": "ZONE",
        }),
        listed(command, ["--template-env", "REGION,ZONE,REGION"]),
        listed(command, [], env={ "SMOCK_TEMPLATE_ENV": "" }),
      ].join(" "),
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|[] [REGION] [REGION,API_BASE,_x1] [REGION,ZONE] [REGION] [REGION,ZONE] []
      #|[] [REGION] [REGION,API_BASE,_x1] [REGION,ZONE] [REGION] [REGION,ZONE] []
      #|[] [REGION] [REGION,API_BASE,_x1] [REGION,ZONE] [REGION] [REGION,ZONE] []
    ),
  )
}

///|
test "a name that is not letters, digits and _ starting with a letter or _, or that starts with SMOCK_, is a usage error" {
  inspect(
    [
      listed("serve", ["--template-env", "1REGION"]),
      listed("serve", ["--template-env", "REGION,API-BASE"]),
      listed("serve", ["--template-env", "REGION, ZONE"]),
      listed("serve", ["--template-env", "REGION,,ZONE"]),
      listed("serve", ["--template-env", "REGION,"]),
      listed("serve", ["--template-env", "RÉGION"]),
      listed("serve", ["--template-env", "SMOCK_ADMIN_TOKEN"]),
      listed("check", [], env={ "SMOCK_TEMPLATE_ENV": "REGION,SMOCK_PORT" }),
      listed("render", ["--template-env", "a.b"]),
    ].join("\n"),
    content=(
      #|invalid value "1REGION" for --template-env (SMOCK_TEMPLATE_ENV): "1REGION" is not an environment variable name: letters, digits and _, starting with a letter or _
      #|invalid value "REGION,API-BASE" for --template-env (SMOCK_TEMPLATE_ENV): "API-BASE" is not an environment variable name: letters, digits and _, starting with a letter or _
      #|invalid value "REGION, ZONE" for --template-env (SMOCK_TEMPLATE_ENV): " ZONE" is not an environment variable name: letters, digits and _, starting with a letter or _
      #|invalid value "REGION,,ZONE" for --template-env (SMOCK_TEMPLATE_ENV): "" is not an environment variable name: letters, digits and _, starting with a letter or _
      #|invalid value "REGION," for --template-env (SMOCK_TEMPLATE_ENV): "" is not an environment variable name: letters, digits and _, starting with a letter or _
      #|invalid value "RÉGION" for --template-env (SMOCK_TEMPLATE_ENV): "RÉGION" is not an environment variable name: letters, digits and _, starting with a letter or _
      #|invalid value "SMOCK_ADMIN_TOKEN" for --template-env (SMOCK_TEMPLATE_ENV): "SMOCK_ADMIN_TOKEN" starts with SMOCK_: smock's own variables cannot be listed
      #|invalid value "REGION,SMOCK_PORT" for --template-env (SMOCK_TEMPLATE_ENV): "SMOCK_PORT" starts with SMOCK_: smock's own variables cannot be listed
      #|invalid value "a.b" for --template-env (SMOCK_TEMPLATE_ENV): "a.b" is not an environment variable name: letters, digits and _, starting with a letter or _
    ),
  )
}
