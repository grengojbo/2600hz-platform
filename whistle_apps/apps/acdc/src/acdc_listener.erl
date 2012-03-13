%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%% Our connection to AMQP and how we handle what payloads we want to
%%% receive, and what module/functions should handle those payloads
%%% when received.
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(acdc_listener).

-behaviour(gen_listener).

%% API
-export([start_link/0, handle_new_member/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_event/2
         ,terminate/2, code_change/3]).

-include("acdc.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

%% By convention, we put the options here in macros, but not required.
-define(BINDINGS, [{queue, []}]).
-define(RESPONDERS, [
                     %% New caller in the call queue
                     {{?MODULE, handle_new_member}, [{<<"queue">>, <<"new_member">>}]}
                    ]).
-define(QUEUE_NAME, wapi_queue:listener_queue_name()).
-define(QUEUE_OPTIONS, []).
-define(ROUTE_OPTIONS, [{exclusive, false}]). %% don't auto-ack the customer

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_listener:start_link(?MODULE, [
                                      {bindings, ?BINDINGS}
                                      ,{responders, ?RESPONDERS}
                                      ,{queue_name, ?QUEUE_NAME}       % optional to include
                                      ,{queue_options, ?QUEUE_OPTIONS} % optional to include
                                      ,{route_options, ?ROUTE_OPTIONS} % optional to include
                                      ,{basic_qos, 1}                % only needed if prefetch controls
                                     ], []).

handle_new_member(JObj, Props, #'basic.deliver'{routing_key=RK}) ->
    [QueueId, AcctDb|_] = lists:reverse(binary:split(RK, <<".">>, [global])),
    lager:debug("recv new member for ~s/~s", [AcctDb, QueueId]),

    {ok, Cache} = acdc_sup:cache_proc(),
    {ok, QPid} = case acdc_util:fetch_queue_pid(Cache, AcctDb, QueueId) of
                     {error, not_found} ->
                         gen_listener:call(props:get_value(server, Props), {start_queue, AcctDb, QueueId});
                     {ok, _}=OK -> OK
                 end,
    acdc_queue:handle_new_member(QPid, JObj).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    put(callid, ?LOG_SYSTEM_ID),
    lager:debug("acdc listener starting"),

    gen_listener:cast(self(), load_queues),
    {ok, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(load_queues, _State) ->
    Queues = [Queue || {_Pid, Ref}=Queue <- start_listeners(), is_reference(Ref)],
    {noreply, Queues}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%%
%% @spec handle_event(JObj, State) -> {reply, Options}
%% @end
%%--------------------------------------------------------------------
handle_event(_JObj, _State) ->
    {reply, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    lager:debug("listener terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
start_listeners() ->
    {ok, Cache} = acdc_sup:cache_proc(),
    lists:foldl(fun(AcctDb, Acc) ->
                        maybe_start_listener(Cache, AcctDb, Acc)
                end, [], whapps_util:get_all_accounts()).

maybe_start_listener(Cache, AcctDb, Acc) ->
    case couch_mgr:get_results(AcctDb, <<"queues/crossbar_listing">>, []) of
        {ok, []} ->
            lager:debug("no queues in account ~s", [AcctDb]),
            Acc;
        {ok, Qs} ->
            lager:debug("starting queues in account ~s", [AcctDb]),
            lists:foldl(fun(QueueId, Acc1) ->
                                [maybe_cache_proc(Cache, AcctDb, QueueId) | Acc1]
                        end, Acc, [wh_json:get_value(<<"id">>, Q) || Q <- Qs]);
        {error, _E} ->
            lager:debug("error getting queues for ~s", [AcctDb]),
            Acc
    end.

-spec maybe_cache_proc/3 :: (pid(), ne_binary(), ne_binary()) -> {pid() | 'error', reference() | term()}.
maybe_cache_proc(Cache, AcctDb, QueueId) ->
    case acdc_util:fetch_queue_pid(Cache, AcctDb, QueueId) of
        {error, not_found} ->
            case acdc_listener_sup:new(AcctDb, QueueId) of
                {ok, Pid} when is_pid(Pid) ->
                    acdc_util:store_queue_pid(Cache, AcctDb, QueueId, Pid),
                    {Pid, erlang:monitor(process, Pid)};
                {error, {already_started, Pid}} ->
                    lager:debug("already started handler for ~s/~s", [AcctDb, QueueId]),
                    {Pid, erlang:monitor(process, Pid)};
                {error, _E}=E ->
                    lager:debug("some error occurred starting ~s/~s: ~p", [AcctDb, QueueId, _E]),
                    E
            end;
        {ok, Pid} ->
            case erlang:process_is_alive(Pid) of
                true ->
                    lager:debug("queue ~s/~s cached at ~p", [AcctDb, QueueId, Pid]),
                    {error, already_cached};
                false ->
                    acdc_util:erase_queue_pid(Cache, AcctDb, QueueId),
                    maybe_cache_proc(Cache, AcctDb, QueueId)
            end
    end.