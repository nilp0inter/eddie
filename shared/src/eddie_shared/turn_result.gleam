/// The outcome of an agent turn — either a successful text response
/// or an error with a reason.
pub type TurnResult {
  TurnSuccess(text: String)
  TurnError(reason: String)
}
