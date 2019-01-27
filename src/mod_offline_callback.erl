%%%
%%% Copyright (C) 2019  Keisoft
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

-module(mod_offline_callback).

-author('harrywatson1008@gmail.com').

-behaviour(gen_mod).

-compile(export_all).
-export([start/2, stop/1, depends/2, mod_opt_type/1, parse_backends/1,
         offline_message/1, health/0]).

-include("logger.hrl").
-include("xmpp.hrl").

-include("mod_offline_callback.hrl").

-define(MODULE_URL, mod_offline_callback_url).
-define(OFFLINE_HOOK_PRIO, 1). % must fire before mod_offline (which has 50)

%
% types
%

-record(url_config,
        {gateway = <<"">> :: binary()}).

-type url_config() :: #url_config{}.

-record(backend_config,
        {type :: backend_type(),
         config :: url_config()}).

-type backend_config() :: #backend_config{}.

%
% dispatch to workers
%

-spec(stanza_to_payload(message()) -> [{atom(), any()}]).

stanza_to_payload(#message{id = Id}) -> [{id, Id}];
stanza_to_payload(_) -> [].

-spec(dispatch(jid(), [{atom(), any()}]) -> ok).

dispatch(#jid{luser = LUser, lserver = LServer},
         Payload) ->
    DisableArgs = {LUser, Timestamp},
    gen_server:cast(backend_worker(BackendId),
                    {dispatch, LUser, Payload, LUser}),
    ok.


%
% ejabberd hooks
%

-spec(offline_message({atom(), message()}) -> {atom(), message()}).

offline_message({_, #message{to = To} = Stanza} = Acc) ->
    Payload = stanza_to_payload(Stanza),
    dispatch(To, Payload),
    Acc.

%
% ejabberd gen_mod callbacks and configuration
%

-spec(start(Host :: binary(), Opts :: [any()]) -> any()).

start(Host, Opts) ->
    ?DEBUG("mod_offline_callback:start(~p, ~p), pid=~p", [Host, Opts, self()]),
    ok = ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message, ?OFFLINE_HOOK_PRIO),

    Results = [start_worker(Host, B) || B <- proplists:get_value(backends, Opts)],
    ?INFO_MSG("++++++++ mod_offline_callback:start(~p, ~p): workers ~p", [Host, Opts, Results]),
    ok.

-spec(stop(Host :: binary()) -> any()).

stop(Host) ->
    ?DEBUG("mod_offline_callback:stop(~p), pid=~p", [Host, self()]),
    ok = ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message, ?OFFLINE_HOOK_PRIO),

    [begin
         Worker = backend_worker({Host, Type}),
         supervisor:terminate_child(ejabberd_gen_mod_sup, Worker),
         supervisor:delete_child(ejabberd_gen_mod_sup, Worker)
     end || #backend_config{type=Type} <- backend_configs(Host)],
    ok.

depends(_, _) ->
    [{mod_offline, hard}].

mod_opt_type(backends) -> fun ?MODULE:parse_backends/1;
mod_opt_type(_) -> [backends].

parse_backends(Plists) ->
    [parse_backend(Plist) || Plist <- Plists].

parse_backend(Opts) ->
    RawType = proplists:get_value(type, Opts),
    Type =
        case lists:member(RawType, [url]) of
            true -> RawType
        end,
    Gateway = proplists:get_value(gateway, Opts),

    #backend_config{
       type = Type,
       config =
           case Type of
               url ->
                   #url_config{gateway = Gateway}
           end
      }.

%
% workers
%

-spec(backend_worker(backend_id()) -> atom()).

backend_worker({Host, Type}) -> gen_mod:get_module_proc(Host, Type).

backend_configs(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, backends,
                           fun(O) when is_list(O) -> O end, []).

-spec(start_worker(Host :: binary(), Backend :: backend_config()) -> ok).

start_worker(Host, #backend_config{type = Type, config = TypeConfig}) ->
    Module = proplists:get_value(Type, [{url, ?MODULE_URL}]),
    Worker = backend_worker({Host, Type}),
    BackendSpec = 
    case Type of
        url ->
                  {Worker,
                   {gen_server, start_link,
                    [{local, Worker}, Module,
                     %% TODO: mb i should send one record like BackendConfig#backend_config.config and parse it in each module
                     [TypeConfig#url_config.gateway], []]},
                   permanent, 1000, worker, [?MODULE]}
    end,

    supervisor:start_child(ejabberd_gen_mod_sup, BackendSpec).

%
% operations
%

health() ->
    Hosts = ejabberd_config:get_myhosts(),
    [{offline_message_hook, [ets:lookup(hooks, {offline_message_hook, H}) || H <- Hosts]}].
