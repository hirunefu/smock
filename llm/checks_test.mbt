// Tests of the load checks the definitions use, through the package's
// public interface.

///|
test "api names one API; any other value is refused with the names it can take" {
  let read = (value : Json) => {
    match @llm.read_api(value) {
      Ok(api) => "\{api.name()}: \{@debug.to_string(api)}"
      Err(message) => message
    }
  }
  inspect(
    [
      read("openai-chat"),
      read("OpenAI-Chat"),
      read("openai-responses"),
      read(""),
      read(1),
      read(Json::null()),
    ].join("\n"),
    content=(
      #|openai-chat: OpenaiChat
      #|must be "openai-chat"
      #|must be "openai-chat"
      #|must be "openai-chat"
      #|must be "openai-chat"
      #|must be "openai-chat"
    ),
  )
}
