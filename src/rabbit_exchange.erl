%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_exchange).
-include_lib("stdlib/include/qlc.hrl").
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-export([recover/0, declare/5, lookup/1, lookup_or_die/1,
         list/1, info/1, info/2, info_all/1, info_all/2,
         simple_publish/6, simple_publish/3,
         route/2]).
-export([add_binding/4, delete_binding/4, list_bindings/1]).
-export([delete/2]).
-export([delete_queue_bindings/1, delete_transient_queue_bindings/1]).
-export([check_type/1, assert_type/2, topic_matches/2]).

%% EXTENDED API
-export([list_exchange_bindings/1]).
-export([list_queue_bindings/1]).

-import(mnesia).
-import(sets).
-import(lists).
-import(qlc).
-import(regexp).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(publish_res() :: {'ok', [pid()]} |
      not_found() | {'error', 'unroutable' | 'not_delivered'}).
-type(bind_res() :: 'ok' | {'error',
                            'queue_not_found' |
                            'exchange_not_found' |
                            'exchange_and_queue_not_found'}).
-spec(recover/0 :: () -> 'ok').
-spec(declare/5 :: (exchange_name(), exchange_type(), bool(), bool(),
                    amqp_table()) -> exchange()).
-spec(check_type/1 :: (binary()) -> atom()).
-spec(assert_type/2 :: (exchange(), atom()) -> 'ok').
-spec(lookup/1 :: (exchange_name()) -> {'ok', exchange()} | not_found()).
-spec(lookup_or_die/1 :: (exchange_name()) -> exchange()).
-spec(list/1 :: (vhost()) -> [exchange()]).
-spec(info/1 :: (exchange()) -> [info()]).
-spec(info/2 :: (exchange(), [info_key()]) -> [info()]).
-spec(info_all/1 :: (vhost()) -> [[info()]]).
-spec(info_all/2 :: (vhost(), [info_key()]) -> [[info()]]).
-spec(simple_publish/6 ::
      (bool(), bool(), exchange_name(), routing_key(), binary(), binary()) ->
             publish_res()).
-spec(simple_publish/3 :: (bool(), bool(), message()) -> publish_res()).
-spec(route/2 :: (exchange(), routing_key()) -> [pid()]).
-spec(add_binding/4 ::
      (exchange_name(), queue_name(), routing_key(), amqp_table()) ->
             bind_res() | {'error', 'durability_settings_incompatible'}).
-spec(delete_binding/4 ::
      (exchange_name(), queue_name(), routing_key(), amqp_table()) ->
             bind_res() | {'error', 'binding_not_found'}).
-spec(list_bindings/1 :: (vhost()) -> 
             [{exchange_name(), queue_name(), routing_key(), amqp_table()}]).
-spec(delete_queue_bindings/1 :: (queue_name()) -> 'ok').
-spec(delete_transient_queue_bindings/1 :: (queue_name()) -> 'ok').
-spec(topic_matches/2 :: (binary(), binary()) -> bool()).
-spec(delete/2 :: (exchange_name(), bool()) ->
             'ok' | not_found() | {'error', 'in_use'}).
-spec(list_queue_bindings/1 :: (queue_name()) -> 
              [{exchange_name(), routing_key(), amqp_table()}]).
-spec(list_exchange_bindings/1 :: (exchange_name()) -> 
              [{queue_name(), routing_key(), amqp_table()}]).

-endif.

%%----------------------------------------------------------------------------

-define(INFO_KEYS, [name, type, durable, auto_delete, arguments].

recover() ->
    ok = rabbit_misc:table_foreach(
           fun(Exchange) -> ok = mnesia:write(Exchange) end,
           durable_exchanges),
    ok = rabbit_misc:table_foreach(
           fun(Route) -> {_, ReverseRoute} = route_with_reverse(Route),
                         ok = mnesia:write(Route),
                         ok = mnesia:write(ReverseRoute)
           end, durable_routes),
    ok.

declare(ExchangeName, Type, Durable, AutoDelete, Args) ->
    Exchange = #exchange{name = ExchangeName,
                         type = Type,
                         durable = Durable,
                         auto_delete = AutoDelete,
                         arguments = Args},
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              case mnesia:wread({exchange, ExchangeName}) of
                  [] -> ok = mnesia:write(Exchange),
                        if Durable ->
                                ok = mnesia:write(
                                       durable_exchanges, Exchange, write);
                           true -> ok
                        end,
                        Exchange;
                  [ExistingX] -> ExistingX
              end
      end).

check_type(<<"fanout">>) ->
    fanout;
check_type(<<"direct">>) ->
    direct;
check_type(<<"topic">>) ->
    topic;
check_type(T) ->
    rabbit_misc:protocol_error(
      command_invalid, "invalid exchange type '~s'", [T]).

assert_type(#exchange{ type = ActualType }, RequiredType)
  when ActualType == RequiredType ->
    ok;
assert_type(#exchange{ name = Name, type = ActualType }, RequiredType) ->
    rabbit_misc:protocol_error(
      not_allowed, "cannot redeclare ~s of type '~s' with type '~s'",
      [rabbit_misc:rs(Name), ActualType, RequiredType]).

lookup(Name) ->
    rabbit_misc:dirty_read({exchange, Name}).

lookup_or_die(Name) ->
    case lookup(Name) of
        {ok, X} -> X;
        {error, not_found} ->
            rabbit_misc:protocol_error(
              not_found, "no ~s", [rabbit_misc:rs(Name)])
    end.

list(VHostPath) ->
    mnesia:dirty_match_object(
      #exchange{name = rabbit_misc:r(VHostPath, exchange), _ = '_'}).

map(VHostPath, F) ->
    %% TODO: there is scope for optimisation here, e.g. using a
    %% cursor, parallelising the function invocation
    lists:map(F, list(VHostPath)).

infos(Items, X) -> [{Item, i(Item, X)} || Item <- Items].

i(name,        #exchange{name        = Name})       -> Name;
i(type,        #exchange{type        = Type})       -> Type;
i(durable,     #exchange{durable     = Durable})    -> Durable;
i(auto_delete, #exchange{auto_delete = AutoDelete}) -> AutoDelete;
i(arguments,   #exchange{arguments   = Arguments})  -> Arguments;
i(Item, _) -> throw({bad_argument, Item}).

info(X = #exchange{}) -> infos(?INFO_KEYS, X).

info(X = #exchange{}, Items) -> infos(Items, X).

info_all(VHostPath) -> map(VHostPath, fun (X) -> info(X) end).

info_all(VHostPath, Items) -> map(VHostPath, fun (X) -> info(X, Items) end).

%% Usable by Erlang code that wants to publish messages.
simple_publish(Mandatory, Immediate, ExchangeName, RoutingKeyBin,
               ContentTypeBin, BodyBin) ->
    {ClassId, _MethodId} = rabbit_framing:method_id('basic.publish'),
    Content = #content{class_id = ClassId,
                       properties = #'P_basic'{content_type = ContentTypeBin},
                       properties_bin = none,
                       payload_fragments_rev = [BodyBin]},
    Message = #basic_message{exchange_name = ExchangeName,
                             routing_key = RoutingKeyBin,
                             content = Content,
                             persistent_key = none},
    simple_publish(Mandatory, Immediate, Message).

%% Usable by Erlang code that wants to publish messages.
simple_publish(Mandatory, Immediate,
               Message = #basic_message{exchange_name = ExchangeName,
                                        routing_key = RoutingKey}) ->
    case lookup(ExchangeName) of
        {ok, Exchange} ->
            QPids = route(Exchange, RoutingKey),
            rabbit_router:deliver(QPids, Mandatory, Immediate,
                                  none, Message);
        {error, Error} -> {error, Error}
    end.

%% return the list of qpids to which a message with a given routing
%% key, sent to a particular exchange, should be delivered.
%%
%% The function ensures that a qpid appears in the return list exactly
%% as many times as a message should be delivered to it. With the
%% current exchange types that is at most once.
%%
%% TODO: Maybe this should be handled by a cursor instead.
route(#exchange{name = Name, type = topic}, RoutingKey) ->
    Query = qlc:q([QName ||
                      #route{binding = #binding{
                               exchange_name = ExchangeName,
                               queue_name = QName,
                               key = BindingKey}} <- mnesia:table(route),
                      ExchangeName == Name,
                      %% TODO: This causes a full scan for each entry
                      %% with the same exchange  (see bug 19336)
                      topic_matches(BindingKey, RoutingKey)]),
    lookup_qpids(
      try
          mnesia:async_dirty(fun qlc:e/1, [Query])
      catch exit:{aborted, {badarg, _}} ->
              %% work around OTP-7025, which was fixed in R12B-1, by
              %% falling back on a less efficient method
              [QName || #route{binding = #binding{queue_name = QName,
                                                  key = BindingKey}} <-
                            mnesia:dirty_match_object(
                              #route{binding = #binding{exchange_name = Name,
                                                        _ = '_'}}),
                        topic_matches(BindingKey, RoutingKey)]
      end);

route(X = #exchange{type = fanout}, _) ->
    route_internal(X, '_');

route(X = #exchange{type = direct}, RoutingKey) ->
    route_internal(X, RoutingKey).

route_internal(#exchange{name = Name}, RoutingKey) ->
    MatchHead = #route{binding = #binding{exchange_name = Name,
                                          queue_name = '$1',
                                          key = RoutingKey,
                                          _ = '_'}},
    lookup_qpids(mnesia:dirty_select(route, [{MatchHead, [], ['$1']}])).

lookup_qpids(Queues) ->
    sets:fold(
      fun(Key, Acc) ->
              case mnesia:dirty_read({amqqueue, Key}) of
                  [#amqqueue{pid = QPid}] -> [QPid | Acc];
                  []                      -> Acc
              end
      end, [], sets:from_list(Queues)).

%% TODO: Should all of the route and binding management not be
%% refactored to its own module, especially seeing as unbind will have
%% to be implemented for 0.91 ?

delete_exchange_bindings(ExchangeName) ->
    indexed_delete(
      #route{binding = #binding{exchange_name = ExchangeName,
                                _ = '_'}}, 
      fun delete_forward_routes/1, fun mnesia:delete_object/1).

delete_queue_bindings(QueueName) ->
    delete_queue_bindings(QueueName, fun delete_forward_routes/1).

delete_transient_queue_bindings(QueueName) ->
    delete_queue_bindings(QueueName, fun delete_transient_forward_routes/1).

delete_queue_bindings(QueueName, FwdDeleteFun) ->
    Exchanges = exchanges_for_queue(QueueName),
    indexed_delete(
      reverse_route(#route{binding = #binding{queue_name = QueueName, 
                                              _ = '_'}}),
      fun mnesia:delete_object/1, FwdDeleteFun),
    [begin
         [X] = mnesia:read({exchange, ExchangeName}),
         ok = maybe_auto_delete(X)
     end || ExchangeName <- Exchanges],
    ok.

indexed_delete(Match, ForwardsDeleteFun, ReverseDeleteFun) ->    
    [begin
         ok = ReverseDeleteFun(reverse_route(Route)),
         ok = ForwardsDeleteFun(Route)
     end || Route <- mnesia:match_object(Match)],
    ok.

delete_forward_routes(Route) ->
    ok = mnesia:delete_object(Route),
    ok = mnesia:delete_object(durable_routes, Route, write).

delete_transient_forward_routes(Route) ->
    ok = mnesia:delete_object(Route).

exchanges_for_queue(QueueName) ->
    MatchHead = reverse_route(
                  #route{binding = #binding{exchange_name = '$1',
                                            queue_name = QueueName,
                                            _ = '_'}}),
    sets:to_list(
      sets:from_list(
        mnesia:select(reverse_route, [{MatchHead, [], ['$1']}]))).

contains(Table, MatchHead) ->
    try
        continue(mnesia:select(Table, [{MatchHead, [], ['$_']}], 1, read))
    catch exit:{aborted, {badarg, _}} ->
            %% work around OTP-7025, which was fixed in R12B-1, by
            %% falling back on a less efficient method
            case mnesia:match_object(Table, MatchHead, read) of
                []    -> false;
                [_|_] -> true
            end
    end.

continue('$end_of_table')    -> false;
continue({[_|_], _})         -> true;
continue({[], Continuation}) -> continue(mnesia:select(Continuation)).

call_with_exchange(Exchange, Fun) ->
    rabbit_misc:execute_mnesia_transaction(
      fun() -> case mnesia:read({exchange, Exchange}) of
                   []  -> {error, not_found};
                   [X] -> Fun(X)
               end
      end).

call_with_exchange_and_queue(Exchange, Queue, Fun) ->
    rabbit_misc:execute_mnesia_transaction(
      fun() -> case {mnesia:read({exchange, Exchange}),
                     mnesia:read({amqqueue, Queue})} of
                   {[X], [Q]} -> Fun(X, Q);
                   {[ ], [_]} -> {error, exchange_not_found};
                   {[_], [ ]} -> {error, queue_not_found};
                   {[ ], [ ]} -> {error, exchange_and_queue_not_found}
               end
      end).

add_binding(ExchangeName, QueueName, RoutingKey, Arguments) ->
    call_with_exchange_and_queue(
      ExchangeName, QueueName,
      fun (X, Q) ->
              if Q#amqqueue.durable and not(X#exchange.durable) ->
                      {error, durability_settings_incompatible};
                 true -> ok = sync_binding(
                            ExchangeName, QueueName, RoutingKey, Arguments,
                            Q#amqqueue.durable, fun mnesia:write/3)
              end
      end).

delete_binding(ExchangeName, QueueName, RoutingKey, Arguments) ->
    call_with_exchange_and_queue(
      ExchangeName, QueueName,
      fun (X, Q) ->
              ok = sync_binding(
                     ExchangeName, QueueName, RoutingKey, Arguments,
                     Q#amqqueue.durable, fun mnesia:delete_object/3),
              maybe_auto_delete(X)
      end).

sync_binding(ExchangeName, QueueName, RoutingKey, Arguments, Durable, Fun) ->
    Binding = #binding{exchange_name = ExchangeName,
                       queue_name = QueueName,
                       key = RoutingKey,
                       args = Arguments},
    ok = case Durable of
             true  -> Fun(durable_routes, #route{binding = Binding}, write);
             false -> ok
         end,
    [ok, ok] = [Fun(element(1, R), R, write) ||
                   R <- tuple_to_list(route_with_reverse(Binding))],
    ok.

list_bindings(VHostPath) ->
    [{ExchangeName, QueueName, RoutingKey, Arguments} ||
        #route{binding = #binding{
                 exchange_name = ExchangeName,
                 key           = RoutingKey, 
                 queue_name    = QueueName,
                 args          = Arguments}}
            <- mnesia:dirty_match_object(
                 #route{binding = #binding{
                          exchange_name = rabbit_misc:r(VHostPath, exchange),
                          _ = '_'},
                        _ = '_'})].

route_with_reverse(#route{binding = Binding}) ->
    route_with_reverse(Binding);
route_with_reverse(Binding = #binding{}) ->
    Route = #route{binding = Binding},
    {Route, reverse_route(Route)}.

reverse_route(#route{binding = Binding}) ->
    #reverse_route{reverse_binding = reverse_binding(Binding)};

reverse_route(#reverse_route{reverse_binding = Binding}) ->
    #route{binding = reverse_binding(Binding)}.

reverse_binding(#reverse_binding{exchange_name = Exchange,
                                 queue_name = Queue,
                                 key = Key,
                                 args = Args}) ->
    #binding{exchange_name = Exchange,
             queue_name = Queue,
             key = Key,
             args = Args};

reverse_binding(#binding{exchange_name = Exchange,
                         queue_name = Queue,
                         key = Key,
                         args = Args}) ->
    #reverse_binding{exchange_name = Exchange,
                     queue_name = Queue,
                     key = Key,
                     args = Args}.

split_topic_key(Key) ->
    {ok, KeySplit} = regexp:split(binary_to_list(Key), "\\."),
    KeySplit.

topic_matches(PatternKey, RoutingKey) ->
    P = split_topic_key(PatternKey),
    R = split_topic_key(RoutingKey),
    topic_matches1(P, R).

topic_matches1(["#"], _R) ->
    true;
topic_matches1(["#" | PTail], R) ->
    last_topic_match(PTail, [], lists:reverse(R));
topic_matches1([], []) ->
    true;
topic_matches1(["*" | PatRest], [_ | ValRest]) ->
    topic_matches1(PatRest, ValRest);
topic_matches1([PatElement | PatRest], [ValElement | ValRest]) when PatElement == ValElement ->
    topic_matches1(PatRest, ValRest);
topic_matches1(_, _) ->
    false.

last_topic_match(P, R, []) ->
    topic_matches1(P, R);
last_topic_match(P, R, [BacktrackNext | BacktrackList]) ->
    topic_matches1(P, R) or last_topic_match(P, [BacktrackNext | R], BacktrackList).

delete(ExchangeName, _IfUnused = true) ->
    call_with_exchange(ExchangeName, fun conditional_delete/1);
delete(ExchangeName, _IfUnused = false) ->
    call_with_exchange(ExchangeName, fun unconditional_delete/1).

maybe_auto_delete(#exchange{auto_delete = false}) ->
    ok;
maybe_auto_delete(Exchange = #exchange{auto_delete = true}) ->
    conditional_delete(Exchange),
    ok.

conditional_delete(Exchange = #exchange{name = ExchangeName}) ->
    Match = #route{binding = #binding{exchange_name = ExchangeName, _ = '_'}},
    %% we need to check for durable routes here too in case a bunch of
    %% routes to durable queues have been removed temporarily as a
    %% result of a node failure
    case contains(route, Match) orelse contains(durable_routes, Match) of
        false  -> unconditional_delete(Exchange);
        true   -> {error, in_use}
    end.

unconditional_delete(#exchange{name = ExchangeName}) ->
    ok = delete_exchange_bindings(ExchangeName),
    ok = mnesia:delete({durable_exchanges, ExchangeName}),
    ok = mnesia:delete({exchange, ExchangeName}).

%%----------------------------------------------------------------------------
%% EXTENDED API
%% These are API calls that are not used by the server internally,
%% they are exported for embedded clients to use

%% This is currently used in mod_rabbit.erl (XMPP) and expects this to
%% return {QueueName, RoutingKey, Arguments} tuples
list_exchange_bindings(ExchangeName) ->
    Route = #route{binding = #binding{exchange_name = ExchangeName,
                                      _ = '_'}},
    [{QueueName, RoutingKey, Arguments} ||
        #route{binding = #binding{queue_name = QueueName,
                                  key = RoutingKey,
                                  args = Arguments}} 
            <- mnesia:dirty_match_object(Route)].

% Refactoring is left as an exercise for the reader
list_queue_bindings(QueueName) ->
    Route = #route{binding = #binding{queue_name = QueueName,
                                      _ = '_'}},
    [{ExchangeName, RoutingKey, Arguments} ||
        #route{binding = #binding{exchange_name = ExchangeName,
                                  key = RoutingKey,
                                  args = Arguments}} 
            <- mnesia:dirty_match_object(Route)].
