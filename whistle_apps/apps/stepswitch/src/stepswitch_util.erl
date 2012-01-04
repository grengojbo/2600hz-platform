%%%-------------------------------------------------------------------
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(stepswitch_util).

-export([lookup_number/1]).
-export([lookup_account_by_number/1]).
-export([evaluate_number/2]).
-export([evaluate_flags/2]).

-include("stepswitch.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec lookup_number/1 :: (ne_binary()) -> {'ok', ne_binary(), boolean()} | {'error', term()}.
lookup_number(Number) ->
    Num = wh_util:to_e164(wh_util:to_binary(Number)),
    case lookup_account_by_number(Num) of
        {ok, AccountId, _}=Ok ->
            ?LOG("~s is associated with account ~s", [Num, AccountId]),
            Ok;
        {error, Reason}=E ->
            ?LOG("~s is not associated with any account, ~p", [Num, Reason]),
            E
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% lookup the account ID by number
%% @end
%%--------------------------------------------------------------------
-spec lookup_account_by_number/1 :: (ne_binary()) -> {'ok', ne_binary(), boolean()} |
                                                     {'error', atom()}.
-spec lookup_account_by_number/2 :: (ne_binary(), pid()) -> {'ok', ne_binary(), boolean()} |
                                                            {'error', atom()}.
lookup_account_by_number(Number) ->
    {ok, Cache} = stepswitch_sup:cache_proc(),
    lookup_account_by_number(Number, Cache).
lookup_account_by_number(Number, Cache) when is_pid(Cache) ->
    case wh_cache:fetch_local(Cache, cache_key_number(Number)) of
        {ok, {AccountId, ForceOut}} ->
            {ok, AccountId, ForceOut};
        {error, not_found} ->
            Options = [{<<"key">>, Number}],
            case couch_mgr:get_results(?ROUTES_DB, ?LIST_ROUTES_BY_NUMBER, Options) of
                {error, _}=E ->
                    E;
                {ok, []} ->
                    {error, not_found};
                {ok, [JObj]} ->
                    AccountId = wh_json:get_value(<<"id">>, JObj),
                    ForceOut = wh_util:is_true(wh_json:get_value([<<"value">>, <<"force_outbound">>], JObj, false)),
                    wh_cache:store_local(Cache, cache_key_number(Number), {AccountId, ForceOut}),
                    {ok, AccountId, ForceOut};
                {ok, [JObj | _Rest]} ->
                    whapps_util:alert(<<"alert">>, ["Source: ~s(~p)~n"
                                                    ,"Alert: Number ~s found more than once in the ~s DB~n"
                                                    ,"Fault: Number should be listed, at most, once~n"
                                                    ,"Call-ID: ~s~n"
                                                   ]
                                      ,[?MODULE, ?LINE, Number, ?ROUTES_DB, get(callid)]),

                    ?LOG("number lookup resulted in more than one result, using the first"),
                    AccountId = wh_json:get_value(<<"id">>, JObj),
                    ForceOut = wh_util:is_true(wh_json:get_value([<<"value">>, <<"force_outbound">>], JObj, false)),
                    wh_cache:store_local(Cache, cache_key_number(Number), {AccountId, ForceOut}),
                    {ok, AccountId, ForceOut}
            end
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Filter the list of resources returning only those with a rule that
%% matches the number.  The list is of tuples with three elements,
%% the weight, the captured component of the number, and the gateways.
%% @end
%%--------------------------------------------------------------------
-spec evaluate_number/2 :: (ne_binary(), [#resrc{}]) -> endpoints().
evaluate_number(Number, Resrcs) ->
    sort_endpoints(get_endpoints(Number, Resrcs)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Filter the list of resources returning only those that have every
%% flag provided
%% @end
%%--------------------------------------------------------------------
-spec evaluate_flags/2 :: (list(), [#resrc{}]) -> [#resrc{}].
evaluate_flags(F1, Resrcs) ->
    [Resrc
     || #resrc{flags=F2}=Resrc <- Resrcs,
        lists:all(fun(Flag) -> lists:member(Flag, F2) end, F1)
    ].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Sort the gateway tuples returned by evalutate_resrcs according to
%% weight.
%% @end
%%--------------------------------------------------------------------
-spec sort_endpoints/1 :: (endpoints()) -> endpoints().
sort_endpoints(Endpoints) ->
    lists:sort(fun({W1, _, _, _, _}, {W2, _, _, _, _}) ->
                       W1 =< W2
               end, Endpoints).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec get_endpoints/2 :: (ne_binary(), [#resrc{}]) -> endpoints().
get_endpoints(Number, Resrcs) ->
    EPs = [get_endpoint(Number, R) || R <- Resrcs],
    [Endpoint || Endpoint <- EPs, Endpoint =/= no_match].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Given a gateway JSON object it builds a gateway record
%% @end
%%--------------------------------------------------------------------
-spec get_endpoint/2 :: (ne_binary(), #resrc{}) -> endpoint() | 'no_match'.
get_endpoint(Number, #resrc{weight_cost=WC, gateways=Gtws, rules=Rules
                            ,grace_period=GP, is_emergency=IsEmergency}) ->
    case evaluate_rules(Rules, Number) of
        {ok, DestNum} ->
            {WC, GP, DestNum, Gtws, IsEmergency};
        {error, no_match} ->
            no_match
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function loops over rules (regex) and until one matches
%% the destination number.  If the matching rule has a
%% capture group return the largest group, otherwise return the whole
%% number.  In the event that no rules match then return an error.
%% @end
%%--------------------------------------------------------------------
-spec evaluate_rules/2 :: (re:mp(), ne_binary()) -> {'ok', ne_binary()} | {'error', 'no_match'}.
evaluate_rules([], _) ->
    {error, no_match};
evaluate_rules([Regex|T], Number) ->
    case re:run(Number, Regex) of
        {match, [{Start,End}]} ->
            {ok, binary:part(Number, Start, End)};
        {match, CaptureGroups} ->
            %% find the largest matching group if present by sorting the position of the
            %% matching groups by list, reverse so head is largest, then take the head of the list
            {Start, End} = hd(lists:reverse(lists:keysort(2, tl(CaptureGroups)))),
            {ok, binary:part(Number, Start, End)};
        _ ->
            evaluate_rules(T, Number)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec cache_key_number/1 :: (ne_binary()) -> {stepswitch_number, ne_binary()}.
cache_key_number(Number) ->
    {stepswitch_number, Number}.