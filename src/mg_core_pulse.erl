%%%
%%% Copyright 2018 RBKmoney
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
-module(mg_core_pulse).

-include_lib("machinegun_core/include/pulse.hrl").

%% API
-export_type([beat/0]).
-export_type([handler/0]).
-export([handle_beat/2]).

-callback handle_beat(Options :: any(), beat()) -> ok.

%%
%% API
%%
-type beat() ::
    % Timer
    #mg_core_timer_lifecycle_created{}
    | #mg_core_timer_lifecycle_rescheduled{}
    | #mg_core_timer_lifecycle_rescheduling_error{}
    | #mg_core_timer_lifecycle_removed{}
    % Scheduler handling
    | #mg_core_scheduler_task_add_error{}
    | #mg_core_scheduler_search_success{}
    | #mg_core_scheduler_search_error{}
    | #mg_core_scheduler_task_error{}
    | #mg_core_scheduler_new_tasks{}
    | #mg_core_scheduler_task_started{}
    | #mg_core_scheduler_task_finished{}
    | #mg_core_scheduler_quota_reserved{}
    % Timer handling
    | #mg_core_timer_process_started{}
    | #mg_core_timer_process_finished{}
    % Machine process state
    | #mg_core_machine_lifecycle_created{}
    | #mg_core_machine_lifecycle_removed{}
    | #mg_core_machine_lifecycle_loaded{}
    | #mg_core_machine_lifecycle_unloaded{}
    | #mg_core_machine_lifecycle_committed_suicide{}
    | #mg_core_machine_lifecycle_failed{}
    | #mg_core_machine_lifecycle_repaired{}
    | #mg_core_machine_lifecycle_loading_error{}
    | #mg_core_machine_lifecycle_transient_error{}
    % Machine call handling
    | #mg_core_machine_process_started{}
    | #mg_core_machine_process_finished{}
    | #mg_core_machine_process_transient_error{}
    % Machine notification
    | #mg_core_machine_notification_created{}
    | #mg_core_machine_notification_delivered{}
    | #mg_core_machine_notification_delivery_error{}
    % Machine worker handling
    | #mg_core_worker_call_attempt{}
    | #mg_core_worker_start_attempt{}
    % Storage calls
    | #mg_core_storage_get_start{}
    | #mg_core_storage_get_finish{}
    | #mg_core_storage_put_start{}
    | #mg_core_storage_put_finish{}
    | #mg_core_storage_search_start{}
    | #mg_core_storage_search_finish{}
    | #mg_core_storage_delete_start{}
    | #mg_core_storage_delete_finish{}
    % Event sink operations
    | #mg_core_events_sink_kafka_sent{}
    % Riak client call handling
    | #mg_core_riak_client_get_start{}
    | #mg_core_riak_client_get_finish{}
    | #mg_core_riak_client_put_start{}
    | #mg_core_riak_client_put_finish{}
    | #mg_core_riak_client_search_start{}
    | #mg_core_riak_client_search_finish{}
    | #mg_core_riak_client_delete_start{}
    | #mg_core_riak_client_delete_finish{}
    % Riak client call handling
    | #mg_core_riak_connection_pool_state_reached{}
    | #mg_core_riak_connection_pool_connection_killed{}
    | #mg_core_riak_connection_pool_error{}.

-type handler() :: mg_core_utils:mod_opts() | undefined.

-spec handle_beat(handler(), any()) -> ok.
handle_beat(undefined, _Beat) ->
    ok;
handle_beat(Handler, Beat) ->
    {Mod, Options} = mg_core_utils:separate_mod_opts(Handler),
    try
        ok = Mod:handle_beat(Options, Beat)
    catch
        Class:Reason:ST ->
            Stacktrace = genlib_format:format_stacktrace(ST),
            Msg = "Pulse handler ~p failed at beat ~p: ~p:~p ~s",
            ok = logger:error(Msg, [{Mod, Options}, Beat, Class, Reason, Stacktrace])
    end.
