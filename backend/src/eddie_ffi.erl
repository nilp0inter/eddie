-module(eddie_ffi).
-export([identity/1, get_env/1, dynamic_to_json/1, now_millis/0, generate_uuid/0]).

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

%% Current time in milliseconds since epoch.
now_millis() ->
    erlang:system_time(millisecond).

%% Generate a UUID v4 string using crypto:strong_rand_bytes.
generate_uuid() ->
    <<A:32, B:16, _:4, C:12, _:2, D:14, E:48>> = crypto:strong_rand_bytes(16),
    Formatted = io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~1.16.0b~3.16.0b-~12.16.0b",
                              [A, B, C, 8 bor (D bsr 12), D band 16#FFF, E]),
    list_to_binary(lists:flatten(Formatted)).
