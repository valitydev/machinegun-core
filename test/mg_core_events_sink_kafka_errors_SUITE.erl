%%%
%%% Copyright 2019 RBKmoney
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

-module(mg_core_events_sink_kafka_errors_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("kafka_protocol/include/kpro_public.hrl").

%% tests descriptions
-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

%% tests
-export([add_events_test/1]).

%% Pulse
-export([handle_beat/2]).

-define(TOPIC, <<"test_event_sink">>).
-define(SOURCE_NS, <<"source_ns">>).
-define(SOURCE_ID, <<"source_id">>).
-define(BROKERS, [{"kafka2", 9092}, {"kafka3", 9092}]).
-define(CLIENT, mg_core_kafka_client).

%%
%% tests descriptions
%%
-type group_name() :: atom().
-type test_name() :: atom().
-type config() :: [{atom(), _}].

-spec all() -> [test_name() | {group, group_name()}].
all() ->
    [
        {group, main}
    ].

-spec groups() -> [{group_name(), list(_), [test_name()]}].
groups() ->
    [
        {main, [], [
            add_events_test
        ]}
    ].

%%
%% starting/stopping
%%
-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    % dbg:tracer(), dbg:p(all, c),
    % dbg:tpl({mg_core_events_sink_kafka, '_', '_'}, x),
    AppSpecs = [
        {ranch, []},
        {machinegun_core, []}
    ],
    Apps = lists:flatten([
        genlib_app:start_application_with(App, AppConf)
     || {App, AppConf} <- AppSpecs
    ]),
    {Events, _} = mg_core_events:generate_events_with_range(
        [{#{}, Body} || Body <- [1, 2, 3]],
        undefined
    ),
    [{apps, Apps}, {events, Events} | C].

-spec end_per_suite(config()) -> ok.
end_per_suite(C) ->
    mg_core_ct_helper:stop_applications(?config(apps, C)).

-spec init_per_testcase(test_name(), config()) -> config().
init_per_testcase(Name, C) ->
    {ok, Proxy = #{endpoint := {Host, Port}}} = ct_proxy:start_link({"kafka1", 9092}),
    Apps =
        genlib_app:start_application_with(brod, [
            {clients, [
                {?CLIENT, [
                    {endpoints, [{Host, Port} | ?BROKERS]},
                    {auto_start_producers, true}
                ]}
            ]}
        ]) ++ ?config(apps, C),
    [{apps, Apps}, {proxy, Proxy}, {testcase, Name} | C].

-spec end_per_testcase(test_name(), config()) -> ok.
end_per_testcase(_Name, C) ->
    _ = (catch ct_proxy:stop(?config(proxy, C))),
    ok.

%%
%% tests
%%

-spec add_events_test(config()) -> _.
add_events_test(C) ->
    ok = change_proxy_mode(pass, stop, C),
    _ = ?assertException(
        throw,
        {transient, {event_sink_unavailable, client_down}},
        mg_core_events_sink_kafka:add_events(
            event_sink_options(),
            ?SOURCE_NS,
            ?SOURCE_ID,
            ?config(events, C),
            null,
            mg_core_deadline:default()
        )
    ).

-spec event_sink_options() -> mg_core_events_sink_kafka:options().
event_sink_options() ->
    #{
        name => kafka,
        client => ?CLIENT,
        topic => ?TOPIC,
        pulse => ?MODULE,
        encoder => fun(NS, ID, Event) ->
            erlang:term_to_binary({NS, ID, Event})
        end
    }.

-spec handle_beat(_, mg_core_pulse:beat()) -> ok.
handle_beat(_, Beat) ->
    ct:pal("~p", [Beat]).

-spec change_proxy_mode(atom(), atom(), config()) -> ok.
change_proxy_mode(ModeWas, Mode, C) ->
    Proxy = ?config(proxy, C),
    _ = ct:pal(
        debug,
        "[~p] setting proxy from '~p' to '~p'",
        [?config(testcase, C), ModeWas, Mode]
    ),
    _ = ?assertEqual({ok, ModeWas}, ct_proxy:mode(Proxy, Mode)),
    ok.
