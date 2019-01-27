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
%%%

-module(mod_offline_callback_url).

-author('harrywatson1008@gmail.com').

-behaviour(gen_server).
-compile(export_all).
-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

-include("logger.hrl").

-define(RETRY_INTERVAL, 30000).

-record(state,
        {send_queue :: queue:queue(any()),
         retry_list :: [any()],
         pending_timer :: reference(),
         retry_timer :: reference(),
         pending_timestamp :: erlang:timestamp(),
         retry_timestamp :: erlang:timestamp(),
         gateway :: string()}).

init([Gateway]) ->
    ?INFO_MSG("+++++++++ mod_pushoff_fcm:init, gateway <~p>", [Gateway]),
    inets:start(),
    crypto:start(),
    ssl:start(),
    {ok, #state{send_queue = queue:new(),
                retry_list = [],
                pending_timer = make_ref(),
                retry_timer = make_ref(),
                gateway = mod_offline_callback_utils:force_string(Gateway)}}.

handle_info({retry, StoredTimestamp},
            #state{send_queue = SendQ,
                   retry_list = RetryList,
                   pending_timer = PendingTimer,
                   retry_timestamp = StoredTimestamp} = State) ->
    case erlang:read_timer(PendingTimer) of
        false -> self() ! send;
        _ -> meh
    end,
    {noreply,
     State#state{send_queue = lists:foldl(fun(E, Q) -> queue:snoc(Q, E) end, SendQ, RetryList),
                 retry_list = []}};

handle_info({retry, _T1}, #state{retry_timestamp = _T2} = State) ->
    {noreply, State};

handle_info(send, #state{send_queue = SendQ,
                         retry_list = RetryList,
                         retry_timer = RetryTimer,
                         gateway = Gateway} = State) ->

    NewState = 
    case mod_offline_callback_utils:enqueue_some(SendQ) of
        empty ->
            State#state{send_queue = SendQ};
        {Head, NewSendQ} ->
            HTTPOptions = [],
            Options = [],
            
            {Body} = pending_element_to_json(Head),
    
            Request = {Gateway, [], "application/json", Body},
            Response = httpc:request(post, Request, HTTPOptions, Options),
            case Response of
                {ok, {{_, StatusCode5xx, _}, _, ErrorBody5xx}} when StatusCode5xx >= 500, StatusCode5xx < 600 ->
                      ?DEBUG("recoverable FCM error: ~p, retrying...", [ErrorBody5xx]),
                      NewRetryList = pending_to_retry(Head, RetryList),
                      {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                      State#state{retry_list = NewRetryList,
                                  send_queue = NewSendQ,
                                  retry_timer = NewRetryTimer,
                                  retry_timestamp = Timestamp};
                {ok, {{_, 200, _}, _, ResponseBody}} ->
                      case parse_response(ResponseBody) of
                          ok -> ok
                        %   _ -> mod_pushoff_mnesia:unregister_client(DisableArgs)
                      end,
                      Timestamp = erlang:timestamp(),
                      State#state{send_queue = NewSendQ,
                                  pending_timestamp = Timestamp
                                  };
    
                {ok, {{_, _, _}, _, ResponseBody}} ->
                      
                      ?DEBUG("non-recoverable http callback error: ~p, delete registration", [ResponseBody]),
                      NewRetryList = pending_to_retry(Head, RetryList),
                      {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                      State#state{retry_list = NewRetryList,
                                  send_queue = NewSendQ,
                                  retry_timer = NewRetryTimer,
                                  retry_timestamp = Timestamp};
    
                {error, Reason} ->
                      ?ERROR_MSG("Callback request failed: ~p, retrying...", [Reason]),
                      NewRetryList = pending_to_retry(Head, RetryList),
                      {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                      State#state{retry_list = NewRetryList,
                                  send_queue = NewSendQ,
                                  retry_timer = NewRetryTimer,
                                  retry_timestamp = Timestamp}
            end
    end,
    {noreply, NewState};

handle_info(Info, State) ->
    ?DEBUG("+++++++ mod_offline_callback_url received unexpected signal ~p", [Info]),
    {noreply, State}.

handle_call(_Req, _From, State) -> {reply, {error, badarg}, State}.

handle_cast({dispatch, UserBare, Payload, ToId},
            #state{send_queue = SendQ,
                   pending_timer = PendingTimer,
                   retry_timer = RetryTimer} = State) ->
    case {erlang:read_timer(PendingTimer), erlang:read_timer(RetryTimer)} of
        {false, false} -> self() ! send;
        _ -> ok
    end,
    {noreply,
     State#state{send_queue = queue:snoc(SendQ, {UserBare, Payload, ToId})}};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

terminate(_Reason, #state{}) ->
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

restart_retry_timer(OldTimer) ->
    erlang:cancel_timer(OldTimer),
    Timestamp = erlang:timestamp(),
    NewTimer = erlang:send_after(?RETRY_INTERVAL, self(), {retry, Timestamp}),
    {NewTimer, Timestamp}.

-spec pending_to_retry(any(), [any()]) -> {[any()]}.

pending_to_retry(Head, RetryList) -> RetryList ++ Head.

pending_element_to_json({_, Payload, ToId}) ->
    Body = proplists:get_value(body, Payload),
    From = proplists:get_value(from, Payload),
    To = proplists:get_value(to, Payload),
    PostMessage = [{body, Body}, {title, From}, {dest, To}, {to, ToId}],
    {jiffy:encode(PostMessage)};

pending_element_to_json(_) ->
    unknown.

parse_response(ResponseBody) ->
    {JsonData} = jiffy:decode(ResponseBody),
    case proplists:get_value(<<"success">>, JsonData) of
        1 ->
            ok;
        _ -> other
    end.
