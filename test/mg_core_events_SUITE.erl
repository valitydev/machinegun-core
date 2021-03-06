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

-module(mg_core_events_SUITE).
-include_lib("common_test/include/ct.hrl").

%% tests descriptions
-export([all/0]).

%% tests
-export([range_direction_test/1]).
-export([range_border_test/1]).
-export([range_missing_params_test/1]).
-export([range_no_intersection_test/1]).
-export([range_partial_intersection_test/1]).

%%
%% tests descriptions
%%
-type test_name() :: atom().
-type config() :: [{atom(), _}].

-spec all() -> [test_name()].
all() ->
    [
        range_direction_test,
        range_no_intersection_test,
        range_partial_intersection_test,
        range_border_test,
        range_missing_params_test
    ].

-spec range_direction_test(config()) -> _.
range_direction_test(_C) ->
    EventsRange = mg_core_dirange:forward(1, 100),
    [4, 3, 2] = get_event_ids(EventsRange, {5, 3, backward}),
    [5, 6, 7, 8] = get_event_ids(EventsRange, {4, 4, forward}).

-spec range_no_intersection_test(config()) -> _.
range_no_intersection_test(_C) ->
    EventsRange = mg_core_dirange:forward(5, 10),
    [] = get_event_ids(EventsRange, {11, 1, forward}),
    [] = get_event_ids(EventsRange, {4, 1, backward}).

-spec range_partial_intersection_test(config()) -> _.
range_partial_intersection_test(_C) ->
    EventsRange = mg_core_dirange:forward(5, 10),
    [5, 6] = get_event_ids(EventsRange, {1, 2, forward}),
    [10, 9] = get_event_ids(EventsRange, {11, 2, backward}).

-spec range_border_test(config()) -> _.
range_border_test(_C) ->
    EventsRange = mg_core_dirange:forward(1, 8),
    [1, 2] = get_event_ids(EventsRange, {undefined, 2, forward}),
    [8, 7] = get_event_ids(EventsRange, {undefined, 2, backward}),
    [6, 7, 8] = get_event_ids(EventsRange, {5, 5, forward}).

-spec range_missing_params_test(config()) -> _.
range_missing_params_test(_C) ->
    EventsRange = mg_core_dirange:forward(1, 8),
    [1, 2, 3] = get_event_ids(EventsRange, {undefined, 3, forward}),
    [7, 8] = get_event_ids(EventsRange, {6, undefined, forward}).

-spec get_event_ids(mg_core_events:events_range(), mg_core_events:history_range()) ->
    [mg_core_events:id()].
get_event_ids(R, HRange) ->
    mg_core_dirange:enumerate(mg_core_events:intersect_range(R, HRange)).
