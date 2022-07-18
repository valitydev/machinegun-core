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

-module(mg_core_circular_buffer).

%%
%% @moduledoc
%% Circular buffer implementation with an ability to configure
%% how many elements are deleted when the buffer is full
%%

%% API Types

-export([new/1]).
-export([new/2]).
-export([push/2]).
-export([member/2]).

-export_type([t/1]).

-opaque t(T) :: {Size :: non_neg_integer(), bounds(), Buffer :: list(T)}.

%% Internal types

-type bounds() :: {UpperBound :: pos_integer(), LowerBound :: non_neg_integer()}.

%%
%% API Functions
%%

-spec new(UpperBound :: pos_integer()) ->
    t(_) | no_return().
new(UpperBound) ->
    new(UpperBound, UpperBound - 1).

-spec new(UpperBound :: pos_integer(), LowerBound :: non_neg_integer()) ->
    t(_) | no_return().
new(UpperBound, LowerBound) when UpperBound > 0, LowerBound >= 0, LowerBound < UpperBound ->
    {0, {UpperBound, LowerBound}, []};
new(_, _) ->
    error(badarg).

-spec push(t(T), T) ->
    t(T).
push({Size, {UpperBound, _} = Bs, Buffer}, Element) when Size < UpperBound ->
    {Size + 1, Bs, [Element | Buffer]};
push({Size, {UpperBound, LowerBound} = Bs, Buffer}, Element) when Size =:= UpperBound ->
    BufferShrunk = rebound(Buffer, Bs),
    {LowerBound + 1, Bs, [Element | BufferShrunk]}.

-spec member(t(T), T) ->
    boolean().
member({_, _, Buffer}, Element) ->
    lists:member(Element, Buffer).

%%
%% Internal Functions
%%

-spec rebound(Buffer :: list(), bounds()) -> Result :: list().
rebound(Buffer, {UpperBound, LowerBound}) when LowerBound =:= UpperBound - 1 ->
    % lists:reverse(tl(lists:reverse(Buffer))),
    lists:droplast(Buffer);
rebound(Buffer, {_, LowerBound}) ->
    pick_n(Buffer, LowerBound).

-spec pick_n(Init :: list(), Amount :: non_neg_integer()) -> Result :: list().
% Basically what lists:droplast/1 does
pick_n(Buffer, Amount) ->
    pick_n(Buffer, Amount, []).

-spec pick_n(Init :: list(), Amount :: non_neg_integer(), Acc :: list()) -> Result :: list().
pick_n(_Buffer, 0, Acc) ->
    lists:reverse(Acc);
pick_n([], _, Acc) ->
    lists:reverse(Acc);
pick_n([H | T], Amount, Acc) ->
    pick_n(T, Amount - 1, [H | Acc]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/assert.hrl").

-spec test() -> _.

-spec circular_buffer_new_test() -> _.
-spec circular_buffer_push_test() -> _.
-spec circular_buffer_push_overflow_test() -> _.
-spec circular_buffer_member_test() -> _.

circular_buffer_new_test() ->
    ?assertEqual({0, {20, 19}, []}, new(20)),
    ?assertError(badarg, new(0)),
    ?assertEqual({0, {20, 10}, []}, new(20, 10)),
    ?assertError(badarg, new(0, 0)),
    ?assertError(badarg, new(10, 10)),
    ?assertError(badarg, new(20, 30)).

circular_buffer_push_test() ->
    Buffer = new(20),
    ?assertMatch({0, _, []}, Buffer),
    ?assertMatch({1, _, [abc]}, push(Buffer, abc)),
    ?assertMatch({2, _, [bcd, abc]}, push(push(Buffer, abc), bcd)).

circular_buffer_push_overflow_test() ->
    Buffer0 = new(2),
    ?assertMatch({2, _, [cbd, bcd]}, push(push(push(Buffer0, abc), bcd), cbd)),
    Buffer1 = new(4, 1),
    ?assertMatch({2, _, [xyz, bde]}, push(push(push(push(push(Buffer1, abc), bcd), cbd), bde), xyz)).

circular_buffer_member_test() ->
    Buffer = push(push(push(new(3), abc), bcd), cbd),
    ?assertEqual(true, member(Buffer, bcd)),
    ?assertEqual(false, member(Buffer, xyz)).

-endif.
