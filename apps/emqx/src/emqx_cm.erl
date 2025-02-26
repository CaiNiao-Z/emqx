%%-------------------------------------------------------------------
%% Copyright (c) 2017-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% Channel Manager
-module(emqx_cm).

-behaviour(gen_server).

-include("emqx.hrl").
-include("logger.hrl").
-include("types.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").


-export([start_link/0]).

-export([ register_channel/3
        , unregister_channel/1
        , insert_channel_info/3
        ]).

-export([connection_closed/1]).

-export([ get_chan_info/1
        , get_chan_info/2
        , set_chan_info/2
        ]).

-export([ get_chan_stats/1
        , get_chan_stats/2
        , set_chan_stats/2
        ]).

-export([get_chann_conn_mod/2]).

-export([ open_session/3
        , discard_session/1
        , discard_session/2
        , takeover_session/1
        , takeover_session/2
        , kick_session/1
        , kick_session/2
        ]).

-export([ lookup_channels/1
        , lookup_channels/2
        ]).

-export([all_channels/0]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

%% Internal export
-export([stats_fun/0]).

-type(chan_pid() :: pid()).

%% Tables for channel management.
-define(CHAN_TAB, emqx_channel).
-define(CHAN_CONN_TAB, emqx_channel_conn).
-define(CHAN_INFO_TAB, emqx_channel_info).

-define(CHAN_STATS,
        [{?CHAN_TAB, 'channels.count', 'channels.max'},
         {?CHAN_TAB, 'sessions.count', 'sessions.max'},
         {?CHAN_CONN_TAB, 'connections.count', 'connections.max'}
        ]).

%% Batch drain
-define(BATCH_SIZE, 100000).

%% Server name
-define(CM, ?MODULE).

-define(T_TAKEOVER, 15000).

%% @doc Start the channel manager.
-spec(start_link() -> startlink_ret()).
start_link() ->
    gen_server:start_link({local, ?CM}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Insert/Update the channel info and stats to emqx_channel table
-spec(insert_channel_info(emqx_types:clientid(),
                          emqx_types:infos(),
                          emqx_types:stats()) -> ok).
insert_channel_info(ClientId, Info, Stats) ->
    Chan = {ClientId, self()},
    true = ets:insert(?CHAN_INFO_TAB, {Chan, Info, Stats}),
    ?tp(debug, insert_channel_info, #{client_id => ClientId}),
    ok.

%% @private
%% @doc Register a channel with pid and conn_mod.
%%
%% There is a Race-Condition on one node or cluster when many connections
%% login to Broker with the same clientid. We should register it and save
%% the conn_mod first for taking up the clientid access right.
%%
%% Note that: It should be called on a lock transaction
register_channel(ClientId, ChanPid, #{conn_mod := ConnMod}) when is_pid(ChanPid) ->
    Chan = {ClientId, ChanPid},
    true = ets:insert(?CHAN_TAB, Chan),
    true = ets:insert(?CHAN_CONN_TAB, {Chan, ConnMod}),
    ok = emqx_cm_registry:register_channel(Chan),
    cast({registered, Chan}).

%% @doc Unregister a channel.
-spec(unregister_channel(emqx_types:clientid()) -> ok).
unregister_channel(ClientId) when is_binary(ClientId) ->
    true = do_unregister_channel({ClientId, self()}),
    ok.

%% @private
do_unregister_channel(Chan) ->
    ok = emqx_cm_registry:unregister_channel(Chan),
    true = ets:delete(?CHAN_CONN_TAB, Chan),
    true = ets:delete(?CHAN_INFO_TAB, Chan),
    ets:delete_object(?CHAN_TAB, Chan).

-spec(connection_closed(emqx_types:clientid()) -> true).
connection_closed(ClientId) ->
    connection_closed(ClientId, self()).

-spec(connection_closed(emqx_types:clientid(), chan_pid()) -> true).
connection_closed(ClientId, ChanPid) ->
    ets:delete_object(?CHAN_CONN_TAB, {ClientId, ChanPid}).

%% @doc Get info of a channel.
-spec(get_chan_info(emqx_types:clientid()) -> maybe(emqx_types:infos())).
get_chan_info(ClientId) ->
    with_channel(ClientId, fun(ChanPid) -> get_chan_info(ClientId, ChanPid) end).

-spec(get_chan_info(emqx_types:clientid(), chan_pid())
      -> maybe(emqx_types:infos())).
get_chan_info(ClientId, ChanPid) when node(ChanPid) == node() ->
    Chan = {ClientId, ChanPid},
    try ets:lookup_element(?CHAN_INFO_TAB, Chan, 2)
    catch
        error:badarg -> undefined
    end;
get_chan_info(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), get_chan_info, [ClientId, ChanPid]).

%% @doc Update infos of the channel.
-spec(set_chan_info(emqx_types:clientid(), emqx_types:attrs()) -> boolean()).
set_chan_info(ClientId, Info) when is_binary(ClientId) ->
    Chan = {ClientId, self()},
    try ets:update_element(?CHAN_INFO_TAB, Chan, {2, Info})
    catch
        error:badarg -> false
    end.

%% @doc Get channel's stats.
-spec(get_chan_stats(emqx_types:clientid()) -> maybe(emqx_types:stats())).
get_chan_stats(ClientId) ->
    with_channel(ClientId, fun(ChanPid) -> get_chan_stats(ClientId, ChanPid) end).

-spec(get_chan_stats(emqx_types:clientid(), chan_pid())
      -> maybe(emqx_types:stats())).
get_chan_stats(ClientId, ChanPid) when node(ChanPid) == node() ->
    Chan = {ClientId, ChanPid},
    try ets:lookup_element(?CHAN_INFO_TAB, Chan, 3)
    catch
        error:badarg -> undefined
    end;
get_chan_stats(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), get_chan_stats, [ClientId, ChanPid]).

%% @doc Set channel's stats.
-spec(set_chan_stats(emqx_types:clientid(), emqx_types:stats()) -> boolean()).
set_chan_stats(ClientId, Stats) when is_binary(ClientId) ->
    set_chan_stats(ClientId, self(), Stats).

-spec(set_chan_stats(emqx_types:clientid(), chan_pid(), emqx_types:stats())
      -> boolean()).
set_chan_stats(ClientId, ChanPid, Stats) ->
    Chan = {ClientId, ChanPid},
    try ets:update_element(?CHAN_INFO_TAB, Chan, {3, Stats})
    catch
        error:badarg -> false
    end.

%% @doc Open a session.
-spec(open_session(boolean(), emqx_types:clientinfo(), emqx_types:conninfo())
      -> {ok, #{session  := emqx_session:session(),
                present  := boolean(),
                pendings => list()}}
       | {error, Reason :: term()}).
open_session(true, ClientInfo = #{clientid := ClientId}, ConnInfo) ->
    Self = self(),
    CleanStart = fun(_) ->
                     ok = discard_session(ClientId),
                     Session = create_session(ClientInfo, ConnInfo),
                     register_channel(ClientId, Self, ConnInfo),
                     {ok, #{session => Session, present => false}}
                 end,
    emqx_cm_locker:trans(ClientId, CleanStart);

open_session(false, ClientInfo = #{clientid := ClientId}, ConnInfo) ->
    Self = self(),
    ResumeStart = fun(_) ->
                      case takeover_session(ClientId) of
                          {ok, ConnMod, ChanPid, Session} ->
                              ok = emqx_session:resume(ClientInfo, Session),
                              Pendings = ConnMod:call(ChanPid, {takeover, 'end'}, ?T_TAKEOVER),
                              register_channel(ClientId, Self, ConnInfo),
                              {ok, #{session  => Session,
                                     present  => true,
                                     pendings => Pendings}};
                          {error, not_found} ->
                              Session = create_session(ClientInfo, ConnInfo),
                              register_channel(ClientId, Self, ConnInfo),
                              {ok, #{session => Session, present => false}}
                      end
                  end,
    emqx_cm_locker:trans(ClientId, ResumeStart).

create_session(ClientInfo, ConnInfo) ->
    Options = get_session_confs(ClientInfo, ConnInfo),
    Session = emqx_session:init(Options),
    ok = emqx_metrics:inc('session.created'),
    ok = emqx_hooks:run('session.created', [ClientInfo, emqx_session:info(Session)]),
    Session.

get_session_confs(#{zone := Zone}, #{receive_maximum := MaxInflight}) ->
    #{max_subscriptions => get_mqtt_conf(Zone, max_subscriptions),
      upgrade_qos => get_mqtt_conf(Zone, upgrade_qos),
      max_inflight => MaxInflight,
      retry_interval => get_mqtt_conf(Zone, retry_interval),
      await_rel_timeout => get_mqtt_conf(Zone, await_rel_timeout),
      mqueue => mqueue_confs(Zone)
     }.

mqueue_confs(Zone) ->
    #{max_len => get_mqtt_conf(Zone, max_mqueue_len),
      store_qos0 => get_mqtt_conf(Zone, mqueue_store_qos0),
      priorities => get_mqtt_conf(Zone, mqueue_priorities),
      default_priority => get_mqtt_conf(Zone, mqueue_default_priority)
     }.

get_mqtt_conf(Zone, Key) ->
    emqx_config:get_zone_conf(Zone, [mqtt, Key]).

%% @doc Try to takeover a session.
-spec(takeover_session(emqx_types:clientid())
      -> {error, term()}
       | {ok, atom(), pid(), emqx_session:session()}).
takeover_session(ClientId) ->
    case lookup_channels(ClientId) of
        [] -> {error, not_found};
        [ChanPid] ->
            takeover_session(ClientId, ChanPid);
        ChanPids ->
            [ChanPid|StalePids] = lists:reverse(ChanPids),
            ?LOG(error, "More than one channel found: ~p", [ChanPids]),
            lists:foreach(fun(StalePid) ->
                                  catch discard_session(ClientId, StalePid)
                          end, StalePids),
            takeover_session(ClientId, ChanPid)
    end.

takeover_session(ClientId, ChanPid) when node(ChanPid) == node() ->
    case get_chann_conn_mod(ClientId, ChanPid) of
        undefined ->
            {error, not_found};
        ConnMod when is_atom(ConnMod) ->
            Session = ConnMod:call(ChanPid, {takeover, 'begin'}, ?T_TAKEOVER),
            {ok, ConnMod, ChanPid, Session}
    end;

takeover_session(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), takeover_session, [ClientId, ChanPid]).

%% @doc Discard all the sessions identified by the ClientId.
-spec(discard_session(emqx_types:clientid()) -> ok).
discard_session(ClientId) when is_binary(ClientId) ->
    case lookup_channels(ClientId) of
        [] -> ok;
        ChanPids -> lists:foreach(fun(Pid) -> do_discard_session(ClientId, Pid) end, ChanPids)
    end.

do_discard_session(ClientId, Pid) ->
    try
        discard_session(ClientId, Pid)
    catch
        _ : noproc -> % emqx_ws_connection: call
            ?tp(debug, "session_already_gone", #{pid => Pid}),
            ok;
        _ : {noproc, _} -> % emqx_connection: gen_server:call
            ?tp(debug, "session_already_gone", #{pid => Pid}),
            ok;
        _ : {'EXIT', {noproc, _}} -> % rpc_call/3
            ?tp(debug, "session_already_gone", #{pid => Pid}),
            ok;
        _ : {{shutdown, _}, _} ->
            ?tp(debug, "session_already_shutdown", #{pid => Pid}),
            ok;
        _ : Error : St ->
            ?tp(error, "failed_to_discard_session",
                #{pid => Pid, reason => Error, stacktrace=>St})
    end.

discard_session(ClientId, ChanPid) when node(ChanPid) == node() ->
    case get_chann_conn_mod(ClientId, ChanPid) of
        undefined -> ok;
        ConnMod when is_atom(ConnMod) ->
            ConnMod:call(ChanPid, discard, ?T_TAKEOVER)
    end;

discard_session(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), discard_session, [ClientId, ChanPid]).

kick_session(ClientId) ->
    case lookup_channels(ClientId) of
        [] -> {error, not_found};
        [ChanPid] ->
            kick_session(ClientId, ChanPid);
        ChanPids ->
            [ChanPid|StalePids] = lists:reverse(ChanPids),
            ?LOG(error, "More than one channel found: ~p", [ChanPids]),
            lists:foreach(fun(StalePid) ->
                                  catch discard_session(ClientId, StalePid)
                          end, StalePids),
            kick_session(ClientId, ChanPid)
    end.

kick_session(ClientId, ChanPid) when node(ChanPid) == node() ->
    case get_chan_info(ClientId, ChanPid) of
        #{conninfo := #{conn_mod := ConnMod}} ->
            ConnMod:call(ChanPid, kick, ?T_TAKEOVER);
        undefined ->
            {error, not_found}
    end;

kick_session(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), kick_session, [ClientId, ChanPid]).

%% @doc Is clean start?
% is_clean_start(#{clean_start := false}) -> false;
% is_clean_start(_Attrs) -> true.

with_channel(ClientId, Fun) ->
    case lookup_channels(ClientId) of
        []    -> undefined;
        [Pid] -> Fun(Pid);
        Pids  -> Fun(lists:last(Pids))
    end.

%% @doc Get all channels registed.
all_channels() ->
    Pat = [{{'_', '$1'}, [], ['$1']}],
    ets:select(?CHAN_TAB, Pat).

%% @doc Lookup channels.
-spec(lookup_channels(emqx_types:clientid()) -> list(chan_pid())).
lookup_channels(ClientId) ->
    lookup_channels(global, ClientId).

%% @doc Lookup local or global channels.
-spec(lookup_channels(local | global, emqx_types:clientid()) -> list(chan_pid())).
lookup_channels(global, ClientId) ->
    case emqx_cm_registry:is_enabled() of
        true ->
            emqx_cm_registry:lookup_channels(ClientId);
        false ->
            lookup_channels(local, ClientId)
    end;

lookup_channels(local, ClientId) ->
    [ChanPid || {_, ChanPid} <- ets:lookup(?CHAN_TAB, ClientId)].

%% @private
rpc_call(Node, Fun, Args) ->
    case rpc:call(Node, ?MODULE, Fun, Args) of
        {badrpc, Reason} -> error(Reason);
        Res -> Res
    end.

%% @private
cast(Msg) -> gen_server:cast(?CM, Msg).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    TabOpts = [public, {write_concurrency, true}],
    ok = emqx_tables:new(?CHAN_TAB, [bag, {read_concurrency, true}|TabOpts]),
    ok = emqx_tables:new(?CHAN_CONN_TAB, [bag | TabOpts]),
    ok = emqx_tables:new(?CHAN_INFO_TAB, [set, compressed | TabOpts]),
    ok = emqx_stats:update_interval(chan_stats, fun ?MODULE:stats_fun/0),
    {ok, #{chan_pmon => emqx_pmon:new()}}.

handle_call(Req, _From, State) ->
    ?LOG(error, "Unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast({registered, {ClientId, ChanPid}}, State = #{chan_pmon := PMon}) ->
    PMon1 = emqx_pmon:monitor(ChanPid, ClientId, PMon),
    {noreply, State#{chan_pmon := PMon1}};

handle_cast(Msg, State) ->
    ?LOG(error, "Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({'DOWN', _MRef, process, Pid, _Reason}, State = #{chan_pmon := PMon}) ->
    ChanPids = [Pid | emqx_misc:drain_down(?BATCH_SIZE)],
    {Items, PMon1} = emqx_pmon:erase_all(ChanPids, PMon),
    ok = emqx_pool:async_submit(fun lists:foreach/2, [fun clean_down/1, Items]),
    {noreply, State#{chan_pmon := PMon1}};

handle_info(Info, State) ->
    ?LOG(error, "Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    emqx_stats:cancel_update(chan_stats).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

clean_down({ChanPid, ClientId}) ->
    do_unregister_channel({ClientId, ChanPid}).

stats_fun() ->
    lists:foreach(fun update_stats/1, ?CHAN_STATS).

update_stats({Tab, Stat, MaxStat}) ->
    case ets:info(Tab, size) of
        undefined -> ok;
        Size -> emqx_stats:setstat(Stat, MaxStat, Size)
    end.

get_chann_conn_mod(ClientId, ChanPid) when node(ChanPid) == node() ->
    Chan = {ClientId, ChanPid},
    try [ConnMod] = ets:lookup_element(?CHAN_CONN_TAB, Chan, 2), ConnMod
    catch
        error:badarg -> undefined
    end;
get_chann_conn_mod(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), get_chann_conn_mod, [ClientId, ChanPid]).

