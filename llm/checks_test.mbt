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
      #|must be "openai-chat" or "openai-responses"
      #|openai-responses: OpenaiResponses
      #|must be "openai-chat" or "openai-responses"
      #|must be "openai-chat" or "openai-responses"
      #|must be "openai-chat" or "openai-responses"
    ),
  )
}

///|
test "a stop reason is a word of the Stub's API; any other value is refused with the API's words" {
  let read = (value : Json) => {
    match @llm.read_stop_reason(OpenaiChat, value) {
      Ok(reason) => "\{value.stringify()}: \{reason.word}"
      Err(message) => "\{value.stringify()}: \{message}"
    }
  }
  inspect(
    [
      read("stop"),
      read("length"),
      read("tool_calls"),
      read("content_filter"),
      read("function_call"),
      read("end_turn"),
      read("max_output_tokens"),
      read("tool_use"),
      read("STOP"),
      read(""),
      read(1),
      read(Json::null()),
    ].join("\n"),
    content=(
      #|"stop": stop
      #|"length": length
      #|"tool_calls": tool_calls
      #|"content_filter": content_filter
      #|"function_call": function_call
      #|"end_turn": must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|"max_output_tokens": must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|"tool_use": must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|"STOP": must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|"": must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|1: must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|null: must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
    ),
  )
}

///|
test "a stop reason of openai-responses is one of its incomplete reasons; a Chat or Anthropic word is refused" {
  let read = (value : Json) => {
    match @llm.read_stop_reason(OpenaiResponses, value) {
      Ok(reason) => "\{value.stringify()}: \{reason.word}"
      Err(message) => "\{value.stringify()}: \{message}"
    }
  }
  inspect(
    [
      read("max_output_tokens"),
      read("max_messages"),
      read("content_filter"),
      read("steered"),
      read("stop"),
      read("length"),
      read("tool_calls"),
      read("end_turn"),
      read("max_tokens"),
      read("incomplete"),
      read("Max_Output_Tokens"),
      read(Json::null()),
    ].join("\n"),
    content=(
      #|"max_output_tokens": max_output_tokens
      #|"max_messages": max_messages
      #|"content_filter": content_filter
      #|"steered": steered
      #|"stop": must be a stop reason of openai-responses: "max_output_tokens", "max_messages", "content_filter" or "steered"
      #|"length": must be a stop reason of openai-responses: "max_output_tokens", "max_messages", "content_filter" or "steered"
      #|"tool_calls": must be a stop reason of openai-responses: "max_output_tokens", "max_messages", "content_filter" or "steered"
      #|"end_turn": must be a stop reason of openai-responses: "max_output_tokens", "max_messages", "content_filter" or "steered"
      #|"max_tokens": must be a stop reason of openai-responses: "max_output_tokens", "max_messages", "content_filter" or "steered"
      #|"incomplete": must be a stop reason of openai-responses: "max_output_tokens", "max_messages", "content_filter" or "steered"
      #|"Max_Output_Tokens": must be a stop reason of openai-responses: "max_output_tokens", "max_messages", "content_filter" or "steered"
      #|null: must be a stop reason of openai-responses: "max_output_tokens", "max_messages", "content_filter" or "steered"
    ),
  )
}
