-module(eddie_ffi).
-export([identity/1, get_env/1, dynamic_to_json/1]).

identity(X) -> X.

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.

%% Re-encode a native Erlang term (from json:decode) back into iodata
%% that gleam_json can embed in its Json type.
dynamic_to_json(Value) ->
    json:encode(Value).
