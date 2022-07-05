-module(mg_core_notification).

%% API

-export([put/6]).
-export([get/3]).
-export([search/4]).
-export([delete/4]).

-type id() :: binary().
-type data() :: #{
    machine_id := mg_core:id(),
    args := term()
}.
-type context() :: mg_core_storage:context().
-type options() :: #{
    namespace := mg_core:ns(),
    pulse := mg_core_pulse:handler(),
    storage := storage_options(),
    storage_retry_policy => mg_core_retry:policy()
}.

-export_type([id/0]).
-export_type([data/0]).
-export_type([context/0]).
-export_type([options/0]).

%% Internal types

% FIXME like mg_core_storage:options() except `name`
-type storage_options() :: mg_core_utils:mod_opts(map()).
-type deadline() :: mg_core_deadline:deadline().
-type ts() :: genlib_time:ts().

%%
%% API
%%

-spec put(id(), data(), ts(), context(), options(), deadline()) -> context().
put(NotificationID, Data, Timestamp, Context, Options, Deadline) ->
    F = fun() ->
        mg_core_storage:put(
            storage_options(Options),
            NotificationID,
            Context,
            data_to_opaque(Data),
            create_indexes(Timestamp)
        )
    end,
    do_with_retry(F, retry_strategy(Options, Deadline)).

-spec get(id(), options(), deadline()) -> {ok, context(), data()} | {error, not_found}.
get(NotificationID, Options, Deadline) ->
    F = fun() ->
        mg_core_storage:get(storage_options(Options), NotificationID)
    end,
    case do_with_retry(F, retry_strategy(Options, Deadline)) of
        undefined ->
            {error, not_found};
        {Context, PackedNotification} ->
            {ok, Context, opaque_to_data(PackedNotification)}
    end.

-spec search(FromTime :: ts(), ToTime :: ts(), options(), deadline()) ->
    mg_core_storage:search_result().
search(FromTime, ToTime, Options, Deadline) ->
    F = fun() ->
        mg_core_storage:search(storage_options(Options), create_index_query(FromTime, ToTime))
    end,
    do_with_retry(F, retry_strategy(Options, Deadline)).

-spec delete(id(), context(), options(), deadline()) -> ok.
delete(NotificationID, Context, Options, Deadline) ->
    F = fun() ->
        mg_core_storage:delete(
            storage_options(Options),
            NotificationID,
            Context
        )
    end,
    do_with_retry(F, retry_strategy(Options, Deadline)).

%%

-define(TIMESTAMP_IDX, {integer, <<"timestamp">>}).

-spec create_indexes(ts()) -> [mg_core_storage:index_update()].
create_indexes(TNow) ->
    [{?TIMESTAMP_IDX, TNow}].

-spec create_index_query(From :: ts(), To :: ts()) -> mg_core_storage:index_query().
create_index_query(FromTime, ToTime) ->
    {?TIMESTAMP_IDX, {FromTime, ToTime}}.

-spec opaque_to_data(mg_core_storage:opaque()) -> data().
opaque_to_data([1, MachineID, Args]) ->
    #{
        machine_id => MachineID,
        args => opaque_to_args(Args)
    }.

-spec opaque_to_args(mg_core_storage:opaque()) -> term().
opaque_to_args(Args) ->
    %% FIXME?
    Args.

-spec data_to_opaque(data()) -> mg_core_storage:opaque().
data_to_opaque(#{
    machine_id := MachineID,
    args := Args
}) ->
    [1, MachineID, args_to_opaque(Args)].

-spec args_to_opaque(term()) -> mg_core_storage:opaque().
args_to_opaque(Args) ->
    %% FIXME?
    Args.

%%

-spec storage_options(options()) -> mg_core_storage:options().
storage_options(#{namespace := NS, storage := StorageOptions, pulse := Handler}) ->
    {Mod, Options} = mg_core_utils:separate_mod_opts(StorageOptions, #{}),
    {Mod, Options#{name => {NS, ?MODULE, notifications}, pulse => Handler}}.

%%

-spec do_with_retry(fun(() -> R), mg_core_retry:strategy()) -> R.
do_with_retry(Fun, RetryStrategy) ->
    try
        Fun()
    catch
        throw:(Reason = {transient, _}):_ST ->
            NextStep = genlib_retry:next_step(RetryStrategy),
            case NextStep of
                {wait, Timeout, NewRetryStrategy} ->
                    ok = timer:sleep(Timeout),
                    do_with_retry(Fun, NewRetryStrategy);
                finish ->
                    throw(Reason)
            end
    end.

-define(DEFAULT_RETRY_POLICY, {exponential, infinity, 2, 10, 60 * 1000}).

-spec retry_strategy(options(), deadline()) -> mg_core_retry:strategy().
retry_strategy(Options, Deadline) ->
    Policy = maps:get(storage_retries, Options, ?DEFAULT_RETRY_POLICY),
    Strategy = mg_core_retry:new_strategy(Policy, undefined, undefined),
    mg_core_retry:constrain(Strategy, Deadline).
