/// Unsafe type coercion for type-erased widget handles.
/// This is used internally when we need to convert a Dynamic value
/// back to its original type at the WidgetHandle boundary.
///
/// SAFETY: The caller must ensure the Dynamic value is actually of
/// the target type. This is guaranteed by the WidgetHandle design
/// where only code that knows the concrete msg type calls send().
@external(erlang, "eddie_ffi", "identity")
pub fn unsafe_coerce(value: a) -> b
