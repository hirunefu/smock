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
      read("anthropic-messages"),
      read("OpenAI-Chat"),
      read("anthropic"),
      read("openai-responses"),
      read(""),
      read(1),
      read(Json::null()),
    ].join("\n"),
    content=(
      #|openai-chat: OpenaiChat
      #|anthropic-messages: AnthropicMessages
      #|must be "openai-chat" or "anthropic-messages"
      #|must be "openai-chat" or "anthropic-messages"
      #|must be "openai-chat" or "anthropic-messages"
      #|must be "openai-chat" or "anthropic-messages"
      #|must be "openai-chat" or "anthropic-messages"
      #|must be "openai-chat" or "anthropic-messages"
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
test "an anthropic-messages stop reason is a word of Anthropic Messages; a Chat or Responses word is refused with Anthropic's words" {
  let read = (value : Json) => {
    match @llm.read_stop_reason(AnthropicMessages, value) {
      Ok(reason) => "\{value.stringify()}: \{reason.word}"
      Err(message) => "\{value.stringify()}: \{message}"
    }
  }
  inspect(
    [
      read("end_turn"),
      read("max_tokens"),
      read("stop_sequence"),
      read("tool_use"),
      read("pause_turn"),
      read("refusal"),
      read("model_context_window_exceeded"),
      read("stop"),
      read("length"),
      read("tool_calls"),
      read("max_output_tokens"),
      read("END_TURN"),
      read(Json::null()),
    ].join("\n"),
    content=(
      #|"end_turn": end_turn
      #|"max_tokens": max_tokens
      #|"stop_sequence": stop_sequence
      #|"tool_use": tool_use
      #|"pause_turn": pause_turn
      #|"refusal": refusal
      #|"model_context_window_exceeded": model_context_window_exceeded
      #|"stop": must be a stop reason of anthropic-messages: "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal" or "model_context_window_exceeded"
      #|"length": must be a stop reason of anthropic-messages: "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal" or "model_context_window_exceeded"
      #|"tool_calls": must be a stop reason of anthropic-messages: "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal" or "model_context_window_exceeded"
      #|"max_output_tokens": must be a stop reason of anthropic-messages: "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal" or "model_context_window_exceeded"
      #|"END_TURN": must be a stop reason of anthropic-messages: "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal" or "model_context_window_exceeded"
      #|null: must be a stop reason of anthropic-messages: "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal" or "model_context_window_exceeded"
    ),
  )
}
