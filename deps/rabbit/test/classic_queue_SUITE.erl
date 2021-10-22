%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(classic_queue_SUITE).
-compile(export_all).

-define(NUM_TESTS, 500).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("proper/include/proper.hrl").

-record(cq, {
    amq = undefined :: amqqueue:amqqueue(),
    name :: atom(),
    mode :: classic | lazy,
    version :: 1 | 2,
    %% @todo durable?
    %% @todo auto_delete?

    q = queue:new() :: queue:queue()
}).

%% Common Test.

all() ->
    [{group, classic_queue_tests}].

groups() ->
    [{classic_queue_tests, [], [
        classic_queue_v1,
        lazy_queue_v1,
        classic_queue_v2,
        lazy_queue_v2
    ]}].

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(Group = classic_queue_tests, Config) ->
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, Group},
        {rmq_nodes_count, 1}
      ]),
    rabbit_ct_helpers:run_steps(Config1,
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps()).

end_per_group(classic_queue_tests, Config) ->
    rabbit_ct_helpers:run_steps(Config,
      rabbit_ct_client_helpers:teardown_steps() ++
      rabbit_ct_broker_helpers:teardown_steps()).
 
classic_queue_v1(Config) ->
    true = rabbit_ct_broker_helpers:rpc(Config, 0,
        ?MODULE, do_classic_queue_v1, [Config]).

do_classic_queue_v1(_) ->
    true = proper:quickcheck(prop_classic_queue_v1(),
                             [{on_output, on_output_fun()},
                              {numtests, ?NUM_TESTS}]).

lazy_queue_v1(Config) ->
    true = rabbit_ct_broker_helpers:rpc(Config, 0,
        ?MODULE, do_lazy_queue_v1, [Config]).

do_lazy_queue_v1(_) ->
    true = proper:quickcheck(prop_lazy_queue_v1(),
                             [{on_output, on_output_fun()},
                              {numtests, ?NUM_TESTS}]).

classic_queue_v2(Config) ->
    true = rabbit_ct_broker_helpers:rpc(Config, 0,
        ?MODULE, do_classic_queue_v2, [Config]).

do_classic_queue_v2(_) ->
    true = proper:quickcheck(prop_classic_queue_v2(),
                             [{on_output, on_output_fun()},
                              {numtests, ?NUM_TESTS}]).

lazy_queue_v2(Config) ->
    true = rabbit_ct_broker_helpers:rpc(Config, 0,
        ?MODULE, do_lazy_queue_v2, [Config]).

do_lazy_queue_v2(_) ->
    true = proper:quickcheck(prop_lazy_queue_v2(),
                             [{on_output, on_output_fun()},
                              {numtests, ?NUM_TESTS}]).

on_output_fun() ->
    fun (".", _) -> ok; % don't print the '.'s on new lines
        ("~n", _) -> ok; % don't print empty lines; CT adds many to logs already
        (F, A) -> io:format(F, A)
    end.

%% Properties.

prop_classic_queue_v1() ->
    InitialState = #cq{name=?FUNCTION_NAME, mode=default, version=1},
    prop_common(InitialState).

prop_lazy_queue_v1() ->
    InitialState = #cq{name=?FUNCTION_NAME, mode=lazy, version=1},
    prop_common(InitialState).

prop_classic_queue_v2() ->
    InitialState = #cq{name=?FUNCTION_NAME, mode=default, version=2},
    prop_common(InitialState).

prop_lazy_queue_v2() ->
    InitialState = #cq{name=?FUNCTION_NAME, mode=lazy, version=2},
    prop_common(InitialState).

prop_common(InitialState) ->
    ?FORALL(Commands, commands(?MODULE, InitialState),
        ?TRAPEXIT(begin
            {History, State, Result} = run_commands(?MODULE, Commands),
            cmd_teardown_queue(State),
            ?WHENFAIL(logger:error("History: ~p~nState: ~p~nResult: ~p",
                                   [History, State, Result]),
                      aggregate(command_names(Commands), Result =:= ok))
        end)
    ).

%% Commands.

%commands:
%   kill
%   terminate
%   recover
%   set version v1/v2
%   ack
%   reject
%   policy_changed
%   consume
%   cancel
%   delete
%   purge
%   requeue
%   ttl behavior

command(St = #cq{amq=undefined}) ->
    {call, ?MODULE, cmd_setup_queue, [St]};
command(St) ->
    weighted_union([
        {100, {call, ?MODULE, cmd_set_mode, [St, oneof([default, lazy])]}},
        {100, {call, ?MODULE, cmd_set_version, [St, oneof([1, 2])]}},
        %% @todo set_mode_version at the same time.
        {900, {call, ?MODULE, cmd_publish_msg, [St, integer(0, 1024*1024)]}},
        {900, {call, ?MODULE, cmd_basic_get_msg, [St]}}
    ]).

%% Next state.

next_state(St, AMQ, {call, _, cmd_setup_queue, _}) ->
    St#cq{amq=AMQ};
next_state(St, _, {call, _, cmd_set_mode, [_, Mode]}) ->
    St#cq{mode=Mode};
next_state(St, _, {call, _, cmd_set_version, [_, Version]}) ->
    St#cq{version=Version};
next_state(St=#cq{q=Q}, Msg, {call, _, cmd_publish_msg, _}) ->
    St#cq{q=queue:in(Msg, Q)};
next_state(St=#cq{q=Q0}, _Msg, {call, _, cmd_basic_get_msg, _}) ->
    %% @todo Should add it to a list of messages that must be acked.
    {_, Q} = queue:out(Q0),
    St#cq{q=Q};
next_state(St, _, _) ->
    St.

%% Preconditions.

%% @todo We probably want to do basic_get when it's empty too!!
precondition(#cq{q=Q}, {call, _, cmd_basic_get_msg, _}) ->
    not queue:is_empty(Q);
precondition(_, _) ->
    true.

%% Postconditions.

postcondition(_, {call, _, cmd_setup_queue, _}, Q) ->
    element(1, Q) =:= amqqueue;
postcondition(#cq{amq=AMQ}, {call, _, cmd_set_mode, [_, Mode]}, _) ->
    do_check_queue_mode(AMQ, Mode) =:= ok;
postcondition(#cq{amq=AMQ}, {call, _, cmd_set_version, [_, Version]}, _) ->
    do_check_queue_version(AMQ, Version) =:= ok;
postcondition(_, {call, _, cmd_publish_msg, _}, Msg) when is_record(Msg, basic_message) ->
    true;
postcondition(#cq{q=Q}, {call, _, cmd_basic_get_msg, _}, Msg) ->
    queue:peek(Q) =:= {value, Msg}.

%% Helpers.

cmd_setup_queue(#cq{name=Name, mode=Mode, version=Version}) ->
    IsDurable = false,
    IsAutoDelete = false,
    %% We cannot use args to set mode/version as the arguments override
    %% the policies and we also want to test policy changes.
    cmd_set_mode_version(Mode, Version),
    %% @todo Maybe have both in-args and in-policies tested.
    Args = [
%        {<<"x-queue-mode">>, longstr, atom_to_binary(Mode, utf8)},
%        {<<"x-queue-version">>, long, Version}
    ],
    QName = rabbit_misc:r(<<"/">>, queue, atom_to_binary(Name, utf8)),
    {new, AMQ} = rabbit_amqqueue:declare(QName, IsDurable, IsAutoDelete, Args, none, <<"acting-user">>),
    %% We check that the queue was creating with the right mode/version.
    ok = do_check_queue_mode(AMQ, Mode),
    ok = do_check_queue_version(AMQ, Version),
    AMQ.

cmd_teardown_queue(#cq{amq=undefined}) ->
    ok;
cmd_teardown_queue(#cq{amq=AMQ}) ->
    rabbit_amqqueue:delete(AMQ, false, false, <<"acting-user">>),
    rabbit_policy:delete(<<"/">>, <<"queue-mode-version-policy">>, <<"acting-user">>),
    ok.

cmd_set_mode(#cq{version=Version}, Mode) ->
    do_set_policy(Mode, Version).

%% We loop until the queue has switched mode.
do_check_queue_mode(AMQ, Mode) ->
    do_check_queue_mode(AMQ, Mode, 1000).

do_check_queue_mode(_, _, 0) ->
    error;
do_check_queue_mode(AMQ, Mode, N) ->
    timer:sleep(1),
    [{backing_queue_status, Status}] = rabbit_amqqueue:info(AMQ, [backing_queue_status]),
    case proplists:get_value(mode, Status) of
        Mode -> ok;
        _ -> do_check_queue_mode(AMQ, Mode, N - 1)
    end.

cmd_set_version(#cq{mode=Mode}, Version) ->
    do_set_policy(Mode, Version).

%% We loop until the queue has switched version.
do_check_queue_version(AMQ, Version) ->
    do_check_queue_version(AMQ, Version, 1000).

do_check_queue_version(_, _, 0) ->
    error;
do_check_queue_version(AMQ, Version, N) ->
    timer:sleep(1),
    [{backing_queue_status, Status}] = rabbit_amqqueue:info(AMQ, [backing_queue_status]),
    case proplists:get_value(version, Status) of
        Version -> ok;
        _ -> do_check_queue_version(AMQ, Version, N - 1)
    end.

cmd_set_mode_version(Mode, Version) ->
    do_set_policy(Mode, Version).

do_set_policy(Mode, Version) ->
    rabbit_policy:set(<<"/">>, <<"queue-mode-version-policy">>, <<".*">>,
        [{<<"queue-mode">>, atom_to_binary(Mode, utf8)},
         {<<"queue-version">>, Version}],
        0, <<"queues">>, <<"acting-user">>).

cmd_publish_msg(#cq{amq=AMQ}, PayloadSize) ->
    Payload = rand:bytes(PayloadSize),
    Msg = rabbit_basic:message(rabbit_misc:r(<<>>, exchange, <<>>),
                               <<>>, #'P_basic'{delivery_mode = 2},
                               Payload),
    %% @todo Confirm/mandatory variants.
    Delivery = #delivery{mandatory = false, sender = self(),
                         confirm = false, message = Msg,% msg_seq_no = Seq,
                         flow = noflow},
    ok = rabbit_amqqueue:deliver([AMQ], Delivery),
    Msg.

cmd_basic_get_msg(#cq{amq=AMQ}) ->
    {ok, Limiter} = rabbit_limiter:start_link(no_id),
    {ok, _CountMinusOne, {_QName, _QPid, _AckTag, false, Msg}, _} =
        rabbit_amqqueue:basic_get(AMQ, true, Limiter,
                                  <<"cmd_basic_get_msg">>,
                                  rabbit_queue_type:init()),
    Msg.
