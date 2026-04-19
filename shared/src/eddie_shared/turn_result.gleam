/// The outcome of an agent turn — either a successful text response
/// or an error with a reason.
import gleam/dynamic/decode
import gleam/json

pub type TurnResult {
  TurnSuccess(text: String)
  TurnError(reason: String)
}

pub fn to_json(result: TurnResult) -> json.Json {
  case result {
    TurnSuccess(text) ->
      json.object([
        #("status", json.string("success")),
        #("text", json.string(text)),
      ])
    TurnError(reason) ->
      json.object([
        #("status", json.string("error")),
        #("reason", json.string(reason)),
      ])
  }
}

pub fn decoder() -> decode.Decoder(TurnResult) {
  use status <- decode.field("status", decode.string)
  case status {
    "success" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TurnSuccess(text:))
    }
    "error" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(TurnError(reason:))
    }
    _ -> decode.failure(TurnError("unknown"), "TurnResult")
  }
}
