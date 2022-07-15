%%%
%%% Copyright 2017 RBKmoney
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%

-module(mg_core_machine_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% tests descriptions
-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).

%% tests
-export([simple_test/1]).

%% mg_core_machine
-behaviour(mg_core_machine).
-export([pool_child_spec/2, process_machine/7]).

-export([start/0]).

%% Pulse
-export([handle_beat/2]).

%%
%% tests descriptions
%%
-type group_name() :: atom().
-type test_name() :: atom().
-type config() :: [{atom(), _}].

-spec all() -> [test_name() | {group, group_name()}].
all() ->
    [
        {group, with_gproc},
        {group, with_consuela}
    ].

-spec groups() -> [{group_name(), list(_), [test_name()]}].
groups() ->
    [
        {with_gproc, [], [{group, base}]},
        {with_consuela, [], [{group, base}]},
        {base, [], [
            simple_test
        ]}
    ].

%%
%% starting/stopping
%%
-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    % dbg:tracer(), dbg:p(all, c),
    % dbg:tpl({mg_core_machine, '_', '_'}, x),
    Apps = mg_core_ct_helper:start_applications([consuela, machinegun_core]),
    [{apps, Apps} | C].

-spec end_per_suite(config()) -> ok.
end_per_suite(C) ->
    mg_core_ct_helper:stop_applications(?config(apps, C)).

-spec init_per_group(group_name(), config()) -> config().
init_per_group(with_gproc, C) ->
    [{registry, mg_core_procreg_gproc} | C];
init_per_group(with_consuela, C) ->
    [{registry, {mg_core_procreg_consuela, #{pulse => ?MODULE}}} | C];
init_per_group(base, C) ->
    C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_, _C) ->
    ok.

%%
%% tests
%%
-define(REQ_CTX, <<"req_ctx">>).

-spec simple_test(config()) -> _.
simple_test(C) ->
    Options = automaton_options(C),
    TestKey = <<"test_key">>,
    ID = <<"42">>,
    Pid = start_automaton(Options),

    {logic, machine_not_found} =
        (catch mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default())),

    ok = mg_core_machine:start(Options, ID, {TestKey, 0}, ?REQ_CTX, mg_core_deadline:default()),
    {logic, machine_already_exist} =
        (catch mg_core_machine:start(
            Options,
            ID,
            {TestKey, 0},
            ?REQ_CTX,
            mg_core_deadline:default()
        )),

    0 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),
    ok = mg_core_machine:call(Options, ID, increment, ?REQ_CTX, mg_core_deadline:default()),
    1 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),
    ok = mg_core_machine:call(Options, ID, delayed_increment, ?REQ_CTX, mg_core_deadline:default()),
    ok = timer:sleep(2000),
    2 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),

    % simple notification
    ok = mg_core_machine:notify(Options, ID, 40, ?REQ_CTX),
    2 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),
    true = mg_core_ct_helper:assert_poll_minimum_time(
        mg_core_ct_helper:poll_for_value(
            fun() ->
                mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default())
            end,
            42,
            3000
        ),
        %% at least 1 second of notification queue handicap
        1000
    ),

    % call fail/simple_repair
    {logic, machine_failed} =
        (catch mg_core_machine:call(Options, ID, fail, ?REQ_CTX, mg_core_deadline:default())),
    ok = mg_core_machine:simple_repair(Options, ID, ?REQ_CTX, mg_core_deadline:default()),
    42 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),

    % call fail/repair
    {logic, machine_failed} =
        (catch mg_core_machine:call(Options, ID, fail, ?REQ_CTX, mg_core_deadline:default())),
    repaired = mg_core_machine:repair(
        Options,
        ID,
        repair_arg,
        ?REQ_CTX,
        mg_core_deadline:default()
    ),
    42 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),

    % fail with notification, repair, retry notification
    ok = mg_core_machine:notify(Options, ID, [<<"kill_when">>, 42], ?REQ_CTX),
    %% wait for notification to kill the machine
    true = mg_core_ct_helper:assert_poll_minimum_time(
        mg_core_ct_helper:poll_for_exception(
            fun() ->
                mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default())
            end,
            {logic, machine_failed},
            5000
        ),
        %% at least 1 second of notification queue handicap
        1000
    ),
    repaired = mg_core_machine:repair(
        Options, ID, repair_arg, ?REQ_CTX, mg_core_deadline:default()
    ),
    %% machine is repaired but notification has not retried yet
    ok = timer:sleep(2000),
    42 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),
    %% wait for notification to kill the machine a second time (it re_tried)
    true = mg_core_ct_helper:assert_poll_minimum_time(
        mg_core_ct_helper:poll_for_exception(
            fun() ->
                mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default())
            end,
            {logic, machine_failed},
            5000
        ),
        %% at least 1 second of notification queue handicap
        1000
    ),
    repaired = mg_core_machine:repair(
        Options, ID, repair_arg, ?REQ_CTX, mg_core_deadline:default()
    ),
    ok = mg_core_machine:call(Options, ID, increment, ?REQ_CTX, mg_core_deadline:default()),
    %% notification no longer kills the machine
    ok = timer:sleep(3000),
    43 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),

    % call fail/repair fail/repair
    {logic, machine_failed} =
        (catch mg_core_machine:call(Options, ID, fail, ?REQ_CTX, mg_core_deadline:default())),
    {logic, machine_failed} =
        (catch mg_core_machine:repair(Options, ID, fail, ?REQ_CTX, mg_core_deadline:default())),
    repaired = mg_core_machine:repair(
        Options,
        ID,
        repair_arg,
        ?REQ_CTX,
        mg_core_deadline:default()
    ),
    {logic, machine_already_working} =
        (catch mg_core_machine:repair(
            Options,
            ID,
            repair_arg,
            ?REQ_CTX,
            mg_core_deadline:default()
        )),
    43 = mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default()),

    ok = mg_core_machine:call(Options, ID, remove, ?REQ_CTX, mg_core_deadline:default()),

    {logic, machine_not_found} =
        (catch mg_core_machine:call(Options, ID, get, ?REQ_CTX, mg_core_deadline:default())),

    ok = stop_automaton(Pid).

%%
%% processor
%%
-spec pool_child_spec(_Options, atom()) -> supervisor:child_spec().
pool_child_spec(_Options, Name) ->
    #{
        id => Name,
        start => {?MODULE, start, []}
    }.

-spec process_machine(
    _Options,
    mg_core:id(),
    mg_core_machine:processor_impact(),
    _,
    _,
    _,
    mg_core_machine:machine_state()
) -> mg_core_machine:processor_result() | no_return().
process_machine(_, _, {_, fail}, _, ?REQ_CTX, _, _) ->
    _ = exit(1),
    {noreply, sleep, []};
process_machine(_, _, {init, {TestKey, TestValue}}, _, ?REQ_CTX, _, null) ->
    {{reply, ok}, sleep, [TestKey, TestValue]};
process_machine(_, _, {call, get}, _, ?REQ_CTX, _, [TestKey, TestValue]) ->
    {{reply, TestValue}, sleep, [TestKey, TestValue]};
process_machine(_, _, {call, increment}, _, ?REQ_CTX, _, [TestKey, TestValue]) ->
    {{reply, ok}, sleep, [TestKey, TestValue + 1]};
process_machine(_, _, {call, delayed_increment}, _, ?REQ_CTX, _, State) ->
    {{reply, ok}, {wait, genlib_time:unow() + 1, ?REQ_CTX, 5000}, State};
process_machine(_, _, {call, remove}, _, ?REQ_CTX, _, State) ->
    {{reply, ok}, remove, State};
process_machine(_, _, {notification, _, [<<"kill_when">>, Arg]}, _, ?REQ_CTX, _, State) ->
    case State of
        [_, Arg] ->
            _ = exit(1);
        _ ->
            {{reply, ok}, sleep, State}
    end;
process_machine(_, _, {notification, _, Arg}, _, ?REQ_CTX, _, [TestKey, TestValue]) when is_integer(Arg) ->
    {{reply, ok}, sleep, [TestKey, TestValue + Arg]};
process_machine(_, _, timeout, _, ?REQ_CTX, _, [TestKey, TestValue]) ->
    {noreply, sleep, [TestKey, TestValue + 1]};
process_machine(_, _, {repair, repair_arg}, _, ?REQ_CTX, _, [TestKey, TestValue]) ->
    {{reply, repaired}, sleep, [TestKey, TestValue]}.

%%
%% utils
%%
-spec start() -> ignore.
start() ->
    ignore.

-spec start_automaton(mg_core_machine:options()) -> pid().
start_automaton(Options) ->
    mg_core_utils:throw_if_error(mg_core_machine:start_link(Options)).

-spec stop_automaton(pid()) -> ok.
stop_automaton(Pid) ->
    ok = proc_lib:stop(Pid, normal, 5000),
    ok.

-spec automaton_options(config()) -> mg_core_machine:options().
automaton_options(C) ->
    Scheduler = #{},
    Namespace = <<"test">>,
    #{
        namespace => Namespace,
        processor => ?MODULE,
        storage => mg_core_storage_memory,
        worker => #{
            registry => ?config(registry, C)
        },
        notification => #{
            namespace => Namespace,
            pulse => ?MODULE,
            storage => mg_core_storage_memory
        },
        notification_scan_handicap => 1,
        notification_reschedule_time => 2,
        pulse => ?MODULE,
        schedulers => #{
            timers => Scheduler,
            timers_retries => Scheduler,
            overseer => Scheduler,
            notification => Scheduler
        }
    }.

-spec handle_beat(_, mg_core_pulse:beat()) -> ok.
handle_beat(_, Beat) ->
    ct:pal("~p", [Beat]).
