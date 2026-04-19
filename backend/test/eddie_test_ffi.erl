-module(eddie_test_ffi).
-export([create_counter/0, increment_counter/1]).

%% Create an atomic counter using an atomics reference.
create_counter() ->
    Ref = atomics:new(1, [{signed, true}]),
    atomics:put(Ref, 1, -1),
    Ref.

%% Atomically increment and return the new value.
increment_counter(Ref) ->
    atomics:add_get(Ref, 1, 1).
