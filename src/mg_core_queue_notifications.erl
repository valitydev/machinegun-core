%%%
%%% Copyright 2022 Valitydev
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

-module(mg_core_queue_notifications).

-include_lib("machinegun_core/include/pulse.hrl").

%% Types

-export([build_task/5]).

-behaviour(mg_core_queue_scanner).
-export([init/1]).
-export([search_tasks/3]).

-behaviour(mg_core_scheduler_worker).
-export([execute_task/2]).

%% Types

-type seconds() :: non_neg_integer().
-type milliseconds() :: non_neg_integer().
-type options() :: #{
    scheduler_id := mg_core_scheduler:id(),
    pulse := mg_core_pulse:handler(),
    machine := mg_core_machine:options(),
    notification := mg_core_notification:options(),
    % how many seconds behind real time we are
    processing_timeout => timeout(),
    min_scan_delay => milliseconds(),
    scan_handicap => seconds(),
    scan_cutoff => seconds(),
    reschedule_time => seconds()
}.

-record(state, {}).

-opaque state() :: #state{}.

-export_type([state/0]).
-export_type([options/0]).

%% Internal types

-type task_id() :: mg_core:id().
-type task_payload() :: #{
    args := mg_core_storage:opaque(),
    context := mg_core_notification:context()
}.
-type target_time() :: mg_core_queue_task:target_time().
-type task() :: mg_core_queue_task:task(task_id(), task_payload()).
-type scan_delay() :: mg_core_queue_scanner:scan_delay().
-type scan_limit() :: mg_core_queue_scanner:scan_limit().

-type fail_action() :: fail_permanently | ignore | {reschedule, target_time()}.

-define(DEFAULT_PROCESSING_TIMEOUT, 5000).
-define(DEFAULT_SCAN_HANDICAP, 10).
% 1 month
-define(DEFAULT_SCAN_CUTOFF, 30 * 24 * 60 * 60).
-define(DEFAULT_RESCHEDULE_TIME, 60).

%%
%% API
%%

-spec build_task(
    NotificationID :: mg_core_notification:id(),
    MachineID :: mg_core:id(),
    Timestamp :: genlib_time:ts(),
    Context :: mg_core_notification:context(),
    Args :: mg_core_storage:opaque()
) ->
    task().
build_task(NotificationID, MachineID, Timestamp, Context, Args) ->
    #{
        id => NotificationID,
        target_time => Timestamp,
        machine_id => MachineID,
        payload => #{
            context => Context,
            args => Args
        }
    }.

-spec init(options()) -> {ok, state()}.
init(_Options) ->
    {ok, #state{}}.

-spec search_tasks(options(), scan_limit(), state()) -> {{scan_delay(), [task()]}, state()}.
search_tasks(Options, Limit, State = #state{}) ->
    CurrentTs = mg_core_queue_task:current_time(),
    ScanHandicap = maps:get(scan_handicap, Options, ?DEFAULT_SCAN_HANDICAP),
    ScanCutoff = maps:get(scan_cutoff, Options, ?DEFAULT_SCAN_CUTOFF),
    TFrom = CurrentTs - ScanHandicap - ScanCutoff,
    TTo = CurrentTs - ScanHandicap,
    {Notifications, Continuation} = mg_core_notification:search(
        notification_options(Options),
        TFrom,
        TTo,
        Limit
    ),
    {Tasks, LastTs} = lists:mapfoldl(
        fun({Ts, NotificationID}, _LastWas) ->
            {create_task(Options, NotificationID, CurrentTs), Ts}
        end,
        CurrentTs,
        Notifications
    ),
    MinDelay = maps:get(min_scan_delay, Options, 1000),
    OptimalDelay =
        case Continuation of
            undefined -> seconds_to_delay(ScanHandicap);
            _Other -> seconds_to_delay(LastTs - CurrentTs)
        end,
    Delay = erlang:max(OptimalDelay, MinDelay),
    {{Delay, Tasks}, State}.

-spec execute_task(options(), task()) -> ok.
execute_task(Options, #{id := NotificationID, machine_id := MachineID, payload := Payload} = Task) ->
    Timeout = maps:get(processing_timeout, Options, ?DEFAULT_PROCESSING_TIMEOUT),
    SchedulerID = maps:get(scheduler_id, Options),
    Deadline = mg_core_deadline:from_timeout(Timeout),
    #{args := Args, context := Context} = Payload,
    try mg_core_machine:send_notification(machine_options(Options), MachineID, NotificationID, Args, Deadline) of
        Result ->
            ok = mg_core_notification:delete(notification_options(Options), NotificationID, Context),
            Result
    catch
        throw:Reason:Stacktrace ->
            Action = task_fail_action(Options, Reason),
            _ =
                case Action of
                    fail_permanently ->
                        ok = mg_core_notification:delete(notification_options(Options), NotificationID, Context);
                    {reschedule, NewTargetTime} ->
                        ok = mg_core_scheduler:send_task(SchedulerID, Task#{target_time => NewTargetTime});
                    ignore ->
                        ok
                end,
            ok = emit_task_failed_beat(Options, MachineID, NotificationID, {throw, Reason, Stacktrace}, Action),
            erlang:raise(throw, Reason, Stacktrace)
    end.

%%
%% Internal functions
%%

-spec seconds_to_delay(_Seconds :: integer()) -> scan_delay().
seconds_to_delay(Seconds) ->
    erlang:convert_time_unit(Seconds, second, millisecond).

-spec machine_options(options()) -> mg_core_machine:options().
machine_options(#{machine := MachineOptions}) ->
    MachineOptions.

-spec notification_options(options()) -> mg_core_notification:options().
notification_options(#{notification := NotificationOptions}) ->
    NotificationOptions.

-spec create_task(options(), mg_core_notification:id(), target_time()) -> task().
create_task(Options, NotificationID, Timestamp) ->
    {ok, Context, #{
        machine_id := MachineID,
        args := Args
    }} = mg_core_notification:get(
        notification_options(Options),
        NotificationID
    ),
    build_task(NotificationID, MachineID, Timestamp, Context, Args).

-spec task_fail_action(options(), mg_core_machine:thrown_error()) -> fail_action().
task_fail_action(_Options, {logic, machine_not_found}) ->
    fail_permanently;
task_fail_action(Options, {transient, _}) ->
    {reschedule, get_reschedule_time(Options)};
task_fail_action(Options, {timeout, _}) ->
    {reschedule, get_reschedule_time(Options)};
task_fail_action(_Options, _) ->
    ignore.

-spec get_reschedule_time(options()) -> target_time().
get_reschedule_time(Options) ->
    Reschedule = maps:get(reschedule_time, Options, ?DEFAULT_RESCHEDULE_TIME),
    Reschedule + genlib_time:unow().

-spec emit_task_failed_beat(
    options(),
    mg_core:id(),
    mg_core_notification:id(),
    mg_core_utils:exception(),
    fail_action()
) -> ok.
emit_task_failed_beat(Options, MachineID, NotificationID, Exception, Action) ->
    ok = emit_beat(Options, #mg_core_machine_notification_failed{
        machine_id = MachineID,
        notification_id = NotificationID,
        exception = Exception,
        action = Action
    }).

-spec emit_beat(options(), mg_core_pulse:beat()) -> ok.
emit_beat(Options, Beat) ->
    ok = mg_core_pulse:handle_beat(maps:get(pulse, Options, undefined), Beat).
