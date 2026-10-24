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
      read("openai-responses"),
      read("anthropic-messages"),
      read("OpenAI-Chat"),
      read("anthropic"),
      read(""),
      read(1),
      read(Json::null()),
    ].join("\n"),
    content=(
      #|openai-chat: OpenaiChat
      #|openai-responses: OpenaiResponses
      #|anthropic-messages: AnthropicMessages
      #|must be "openai-chat", "openai-responses" or "anthropic-messages"
      #|must be "openai-chat", "openai-responses" or "anthropic-messages"
      #|must be "openai-chat", "openai-responses" or "anthropic-messages"
      #|must be "openai-chat", "openai-responses" or "anthropic-messages"
      #|must be "openai-chat", "openai-responses" or "anthropic-messages"
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

///|
test "an error gives its type for openai-chat and anthropic-messages, and its code for openai-responses" {
  let apis : Array[@llm.Api] = [OpenaiChat, OpenaiResponses, AnthropicMessages]
  inspect(
    apis.map(api => "\{api.name()}: \{@llm.error_kind_member(api)}").join("\n"),
    content=(
      #|openai-chat: type
      #|openai-responses: code
      #|anthropic-messages: type
    ),
  )
}

///|
test "an OpenAI error's type or code is any non-empty string; anything else is refused" {
  let read = (api : @llm.Api, value : Json) => {
    match @llm.read_error_kind(api, value) {
      Ok(kind) => "\{api.name()} \{value.stringify()}: \{kind}"
      Err(message) => "\{api.name()} \{value.stringify()}: \{message}"
    }
  }
  inspect(
    [
      read(OpenaiChat, "server_error"),
      read(OpenaiChat, "overloaded_error"),
      read(OpenaiChat, "x"),
      read(OpenaiChat, ""),
      read(OpenaiChat, 1),
      read(OpenaiChat, Json::null()),
      read(OpenaiResponses, "server_error"),
      read(OpenaiResponses, "rate_limit_exceeded"),
      read(OpenaiResponses, ""),
      read(OpenaiResponses, ["server_error"]),
    ].join("\n"),
    content=(
      #|openai-chat "server_error": server_error
      #|openai-chat "overloaded_error": overloaded_error
      #|openai-chat "x": x
      #|openai-chat "": must be a non-empty string
      #|openai-chat 1: must be a non-empty string
      #|openai-chat null: must be a non-empty string
      #|openai-responses "server_error": server_error
      #|openai-responses "rate_limit_exceeded": rate_limit_exceeded
      #|openai-responses "": must be a non-empty string
      #|openai-responses ["server_error"]: must be a non-empty string
    ),
  )
}

///|
test "an anthropic-messages error's type is one of Anthropic's documented error types; any other value is refused with the list" {
  let read = (value : Json) => {
    match @llm.read_error_kind(AnthropicMessages, value) {
      Ok(kind) => "\{value.stringify()}: \{kind}"
      Err(message) => "\{value.stringify()}: \{message}"
    }
  }
  inspect(
    [
      read("invalid_request_error"),
      read("authentication_error"),
      read("billing_error"),
      read("permission_error"),
      read("not_found_error"),
      read("conflict_error"),
      read("request_too_large"),
      read("rate_limit_error"),
      read("api_error"),
      read("timeout_error"),
      read("overloaded_error"),
      read("server_error"),
      read("Overloaded_Error"),
      read(""),
      read(529),
    ].join("\n"),
    content=(
      #|"invalid_request_error": invalid_request_error
      #|"authentication_error": authentication_error
      #|"billing_error": billing_error
      #|"permission_error": permission_error
      #|"not_found_error": not_found_error
      #|"conflict_error": conflict_error
      #|"request_too_large": request_too_large
      #|"rate_limit_error": rate_limit_error
      #|"api_error": api_error
      #|"timeout_error": timeout_error
      #|"overloaded_error": overloaded_error
      #|"server_error": must be an error type of anthropic-messages: "invalid_request_error", "authentication_error", "billing_error", "permission_error", "not_found_error", "conflict_error", "request_too_large", "rate_limit_error", "api_error", "timeout_error" or "overloaded_error"
      #|"Overloaded_Error": must be an error type of anthropic-messages: "invalid_request_error", "authentication_error", "billing_error", "permission_error", "not_found_error", "conflict_error", "request_too_large", "rate_limit_error", "api_error", "timeout_error" or "overloaded_error"
      #|"": must be an error type of anthropic-messages: "invalid_request_error", "authentication_error", "billing_error", "permission_error", "not_found_error", "conflict_error", "request_too_large", "rate_limit_error", "api_error", "timeout_error" or "overloaded_error"
      #|529: must be an error type of anthropic-messages: "invalid_request_error", "authentication_error", "billing_error", "permission_error", "not_found_error", "conflict_error", "request_too_large", "rate_limit_error", "api_error", "timeout_error" or "overloaded_error"
    ),
  )
}

///|
test "an error's after may reach the end of the text, counted in code points, and not pass it" {
  let check = (after : Int32, strings : @llm.Strings) => {
    match @llm.check_error_after(after, strings.text) {
      Ok(_) => "\{after}: ok"
      Err(message) => "\{after}: \{message}"
    }
  }
  let text = @llm.Strings(text="👍🏽 Hi")
  let chunks = @llm.Strings(chunks=["", "Hel", "", "lo"])
  let empty = @llm.Strings(tool_calls=[@llm.ToolCall(name="f", arguments={})])
  inspect(
    [
      check(0, text),
      check(5, text),
      check(6, text),
      check(5, chunks),
      check(6, chunks),
      check(0, empty),
      check(1, empty),
      check(2, @llm.Strings(text="a")),
    ].join("\n"),
    content=(
      #|0: ok
      #|5: ok
      #|6: is past the end of the text, which has 5 code points
      #|5: ok
      #|6: is past the end of the text, which has 5 code points
      #|0: ok
      #|1: is past the end of the text, which has 0 code points
      #|2: is past the end of the text, which has 1 code point
    ),
  )
}
