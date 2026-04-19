/// HTTP execution layer — sends requests and returns responses.
///
/// This is the only module that performs actual network IO.
/// Everything else in Eddie is sans-IO.
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc

/// Errors that can occur when sending an HTTP request.
pub type HttpError {
  /// The HTTP client returned an error
  RequestFailed(httpc.HttpError)
}

/// Send an HTTP request and return the response.
pub fn send(
  request request: Request(String),
) -> Result(Response(String), HttpError) {
  httpc.send(request)
  |> result_map_error(RequestFailed)
}

/// Map an error type (gleam/result.map_error inlined to avoid extra import)
fn result_map_error(
  result: Result(a, e1),
  mapper: fn(e1) -> e2,
) -> Result(a, e2) {
  case result {
    Ok(value) -> Ok(value)
    Error(err) -> Error(mapper(err))
  }
}
