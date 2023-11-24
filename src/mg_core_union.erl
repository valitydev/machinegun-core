-module(mg_core_union).

-behaviour(gen_server).

-export([start_link/1]).
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([child_spec/1]).
-export([discovery/1]).

-define(SERVER, ?MODULE).
-define(RECONNECT_TIMEOUT, 5000).

-type discovery_options() :: #{
    module := atom(),
    %% options is module specific structure
    options := term()
}.
-type dns_discovery_options() :: #{
    %% #{<<"domain_name">> => <<"machinegun-ha-headless">>,<<"sname">> => <<"machinegun">>}
    binary() => binary()
}.
-type cluster_options() :: #{
    discovery := discovery_options(),
    reconnect_timeout := non_neg_integer()
}.
-type state() :: #{
    known_nodes => [node()],
    discovery => discovery_options(),
    reconnect_timeout => non_neg_integer()
}.

%% discovery behaviour callback
-callback discovery(dns_discovery_options()) -> {ok, [node()]}.

%% API
-spec child_spec(cluster_options()) -> [supervisor:child_spec()].
child_spec(#{discovery := _} = ClusterOpts) ->
    [
        #{
            id => ?MODULE,
            start => {?MODULE, start_link, [ClusterOpts]}
        }
    ];
child_spec(_) ->
    % cluster not configured, skip
    [].

-spec discovery(dns_discovery_options()) -> {ok, [node()]}.
discovery(#{<<"domain_name">> := DomainName, <<"sname">> := Sname}) ->
    case get_addrs(unicode:characters_to_list(DomainName)) of
        {ok, ListAddrs} ->
            logger:info("resolve ~p with result: ~p", [DomainName, ListAddrs]),
            {ok, addrs_to_nodes(ListAddrs, Sname)};
        Error ->
            error({resolve_error, Error})
    end.

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================
-spec start_link(cluster_options()) -> {ok, pid()} | {error, term()}.
start_link(ClusterOpts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, ClusterOpts, []).

-spec init(cluster_options()) -> {ok, state(), {continue, {full_init, cluster_options()}}}.
init(ClusterOpts) ->
    logger:info("init cluster with options: ~p", [ClusterOpts]),
    {ok, #{}, {continue, {full_init, ClusterOpts}}}.

-spec handle_continue({full_init, cluster_options()}, state()) -> {noreply, state()}.
handle_continue({full_init, #{discovery := #{module := Mod, options := Opts}} = ClusterOpts}, _State) ->
    _ = net_kernel:monitor_nodes(true),
    {ok, ListNodes} = Mod:discovery(Opts),
    _ = try_connect_all(ListNodes, maps:get(reconnect_timeout, ClusterOpts)),
    {noreply, ClusterOpts#{known_nodes => ListNodes}}.

-spec handle_call(term(), {pid(), _}, state()) -> {reply, any(), state()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({timeout, _TRef, {reconnect, Node}}, State) ->
    ListNodes = maybe_connect(Node, State),
    {noreply, State#{known_nodes => ListNodes}};
handle_info({nodeup, RemoteNode}, #{known_nodes := ListNodes} = State) ->
    logger:info("~p receive nodeup ~p", [node(), RemoteNode]),
    NewState =
        case lists:member(RemoteNode, ListNodes) of
            true ->
                %% well known node connected
                State;
            false ->
                %% new node connected, need update list nodes
                #{discovery := #{module := Mod, options := Opts}, reconnect_timeout := Timeout} = State,
                {ok, NewListNodes} = Mod:discovery(Opts),
                _ = try_connect_all(ListNodes, Timeout),
                State#{known_nodes => NewListNodes}
        end,
    {noreply, NewState};
handle_info({nodedown, RemoteNode}, #{reconnect_timeout := Timeout} = State) ->
    logger:warning("~p receive nodedown ~p", [node(), RemoteNode]),
    _ = erlang:start_timer(Timeout, self(), {reconnect, RemoteNode}),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(_Reason, state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(_OldVsn, state(), _Extra) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% cluster functions
-spec connect(node(), non_neg_integer()) -> ok | error.
connect(Node, ReconnectTimeout) ->
    case net_adm:ping(Node) of
        pong ->
            ok;
        _ ->
            _ = erlang:start_timer(ReconnectTimeout, self(), {reconnect, Node}),
            error
    end.

-spec try_connect_all([node()], non_neg_integer()) -> ok.
try_connect_all(ListNodes, ReconnectTimeout) ->
    _ = lists:foreach(fun(Node) -> connect(Node, ReconnectTimeout) end, ListNodes).

-spec maybe_connect(node(), state()) -> [node()].
maybe_connect(Node, #{discovery := #{module := Mod, options := Opts}, reconnect_timeout := Timeout}) ->
    {ok, ListNodes} = Mod:discovery(Opts),
    case lists:member(Node, ListNodes) of
        false ->
            %% node deleted from cluster, do nothing
            skip;
        true ->
            connect(Node, Timeout)
    end,
    ListNodes.

%% discovery functions
-spec get_addrs(inet:hostname()) -> {ok, [inet:ip_address()]} | {error, _}.
get_addrs(DomainName) ->
    case inet:getaddrs(DomainName, inet) of
        {ok, _} = Ok -> Ok;
        _ -> inet:getaddrs(DomainName, inet6)
    end.

-spec addrs_to_nodes([inet:ip_address()], binary()) -> [node()].
addrs_to_nodes(ListAddrs, Sname) ->
    NodeName = unicode:characters_to_list(Sname),
    lists:foldl(
        fun(Addr, Acc) ->
            [erlang:list_to_atom(NodeName ++ "@" ++ inet:ntoa(Addr)) | Acc]
        end,
        [],
        ListAddrs
    ).
