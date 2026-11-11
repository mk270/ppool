% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

-module(ppool_tests).
-include_lib("eunit/include/eunit.hrl").
-export([test_mfa/1, wait_mfa/1]).
-export([start_worker/1, init_exit/0]).

%%% All Test Fixtures
start_test_() ->
    {"It should be possible to start a pool server and give it a name",
     {setup,
      fun find_unique_name/0,
      fun(Name) ->
        [start_and_test_name(Name)]
      end}}.

mfa_test_() ->
    {"A pool process can be allocated which will be ordered "
     "to run an MFA call determined at start time, with arguments "
     "provided at call time",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun(Name) ->
        [pool_run_mfa(Name)]
      end}
    }.

alloc_test_() ->
    {"A pool process can be allocated which will be ordered "
     "to run a worker, only if there are enough which "
     "haven't been ordered to run yet.",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun(Name) ->
        [pool_run_alloc(Name),
         pool_run_noalloc(Name)]
      end}
    }.

realloc_test_() ->
    {"When an allocated process dies, "
     "A new one can be allocated to replace it.",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun(Name) ->
        [pool_run_realloc(Name)]
      end}
    }.

queue_test_() ->
    {"The queue function can be used to run the function as soon as possible. "
     "If no space is available, the worker call is added to the queue.",
     {foreach,
      fun start_ppool/0,
      fun kill_ppool/1,
      [fun(Name) -> test_async_queue(Name) end,
       fun(Name) -> test_sync_queue(Name) end]}
    }.

supervision_test_() ->
    {"The ppool will never restart a dead child, but all children (OTP "
     "compliant) will be shut down when closing the pool, even if they "
     "are trapping exits",
     {setup,
      fun find_unique_name/0,
      fun test_supervision/1}}.
    
auth_test_() ->
    {"The ppool should only dequeue tasks after receiving a down signal "
     "from a worker and nobody else",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun test_auth_dealloc/1}}.

%%% Setups/teardowns
find_unique_name() ->
    application:start(ppool),
    Name = list_to_atom(lists:flatten(io_lib:format("~p",[now()]))),
    ?assertEqual(undefined, whereis(Name)),
    Name.

start_ppool() ->
    Name = find_unique_name(),
    ppool:start_pool(Name, 2, {ppool_nagger, start_link, []}),
    Name.

kill_ppool(Name) ->
    ppool:stop_pool(Name).
    
%%% Actual tests
start_and_test_name(Name) ->
    ppool:start_pool(Name, 1, {ppool_nagger, start_link, []}),
    A = whereis(Name),
    ppool:stop_pool(Name),
    timer:sleep(100),
    B = whereis(Name),
    [?_assert(undefined =/= A),
     ?_assertEqual(undefined, B)].

pool_run_mfa(Name) ->
    ppool:run(Name, [i_am_running, 1, 1, self()]),
    X = receive
        {_Pid, i_am_running} -> ok
    after 3000 ->
        timeout
    end,
    ?_assertEqual(ok, X).

pool_run_alloc(Name) ->
    {ok, Pid} = ppool:run(Name, [i_am_running, 1, 1, self()]),
    X = receive
        {Pid, i_am_running} -> ok
    after 3000 ->
        timeout
    end,
    [?_assert(is_pid(Pid)),
     ?_assertEqual(ok, X)].

pool_run_noalloc(Name) ->
    %% Init function should have set the limit to 2
    ppool:run(Name, [i_am_running, 300, 1, self()]),
    ppool:run(Name, [i_am_running, 300, 1, self()]),
    X = ppool:run(Name, [i_am_running, 1, 1, self()]),
    ?_assertEqual(noalloc, X).
    
pool_run_realloc(Name) ->
    %% Init function should have set the limit to 2
    {ok, A} = ppool:run(Name, [i_am_running, 500, 1, self()]),
    timer:sleep(100),
    {ok, B} = ppool:run(Name, [i_am_running, 500, 1, self()]),
    timer:sleep(600),
    {ok, Pid} = ppool:run(Name, [i_am_running, 1, 1, self()]),
    timer:sleep(100),
    L = flush(),
    [?_assert(is_pid(Pid)),
     ?_assertEqual([{A,i_am_running}, {B,i_am_running}, {Pid,i_am_running}],
                   L)].

test_async_queue(Name) ->
    %% Still two elements max!
    ok = ppool:async_queue(Name, [i_am_running, 2000, 1, self()]),
    ok = ppool:async_queue(Name, [i_am_running, 2000, 1, self()]),
    noalloc = ppool:run(Name, [i_am_running, 2000, 1, self()]),
    ok = ppool:async_queue(Name, [i_am_running, 500, 1, self()]),
    timer:sleep(3500),
    L = flush(),
    ?_assertMatch([{_, i_am_running}, {_, i_am_running}, {_, i_am_running}], L).

test_sync_queue(Name) ->
    %% Hell yase, two max
    {ok, Pid} = ppool:sync_queue(Name, [i_am_running, 200, 1, self()]),
    ok = ppool:async_queue(Name, [i_am_running, 200, 1, self()]),
    ok = ppool:async_queue(Name, [i_am_running, 200, 1, self()]),
    {ok, Pid2} = ppool:sync_queue(Name, [i_am_running, 100, 1, self()]),
    timer:sleep(300),
    L = flush(),
    [?_assert(is_pid(Pid)),
     ?_assert(is_pid(Pid2)),
     ?_assertMatch([{_,i_am_running}, {_,i_am_running},
                    {_,i_am_running}, {_,i_am_running}],
                   L)].

test_supervision(Name) ->
    ppool:start_pool(Name, 1, {ppool_nagger, start_link, []}),
    {ok, Pid} = ppool:run(Name, [sup, 10000, 100, self()]),
    ppool:stop_pool(Name),
    timer:sleep(100),
    ?_assertEqual(undefined, process_info(Pid)). 

test_auth_dealloc(Name) ->
    %% Hell yase, two max
    {ok, _Pid} = ppool:sync_queue(Name, [i_am_running, 500, 1, self()]),
    ok = ppool:async_queue(Name, [i_am_running, 10000, 1, self()]),
    ok = ppool:async_queue(Name, [i_am_running, 10000, 1, self()]),
    ok = ppool:async_queue(Name, [i_am_running, 1, 1, self()]),
    timer:sleep(600),
    Name ! {'DOWN', make_ref(), process, self(), normal},
    Name ! {'DOWN', make_ref(), process, self(), normal},
    Name ! {'DOWN', make_ref(), process, self(), normal},
    timer:sleep(200),
    L = flush(),
    ?_assertMatch([{_,i_am_running}], L).
    


flush() ->
    receive
        X -> [X|flush()]
    after 0 ->
        []
    end.

%% Exported Helper functions
test_mfa(Pid) ->
    Pid ! i_am_running.

wait_mfa(Pid) ->
    Pid ! i_am_running,
    timer:sleep(3000).

%%% A pool that does not exist is an error for every call that goes
%%% via the pool server: an exit with noproc (stop_pool/1 returns
%%% {error, not_found}).  In particular async_queue/2 must not report
%%% success.
missing_pool_test_() ->
    {"Calls to a pool that does not exist are reported as errors; "
     "calls to a live pool are unaffected",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun(Name) ->
        Missing = missing_pool_name(),
        [?_assertExit({noproc, _}, ppool:run(Missing, [x])),
         ?_assertExit({noproc, _}, ppool:sync_queue(Missing, [x])),
         ?_assertExit({noproc, _}, ppool:async_queue(Missing, [x])),
         ?_assertExit({noproc, _}, ppool:status(Missing)),
         ?_assertEqual({error, not_found}, ppool:stop_pool(Missing)),
         ?_test(live_pool_unchanged(Name))]
      end}}.

missing_pool_name() ->
    list_to_atom("nopool_" ++
                 integer_to_list(erlang:unique_integer([positive]))).

live_pool_unchanged(Name) ->
    Me = self(),
    ?assertEqual(ok, ppool:async_queue(Name, [async_ok, 100, 1, Me])),
    ?assertMatch({ok, _}, ppool:run(Name, [run_ok, 100, 1, Me])),
    ?assertMatch({ok, _}, ppool:sync_queue(Name, [sync_ok, 100, 1, Me])),
    ?assertMatch({state, _, _, _, _, Name}, ppool:status(Name)).

%%% A worker that fails to start must not take the pool down.
%%%
%%% Each test gets a fresh pool (limit 2) whose start function is
%%% start_worker/1 below, so the first run/2 argument picks how the
%%% worker behaves.  The actions are inside the tests, so a crash in
%%% the pool is a test failure, not a fixture failure.
failed_start_test_() ->
    {"A worker that fails to start is reported to its caller (or "
     "logged and dropped, for the queue); the pool, its running "
     "workers and the rest of its queue are not affected, and no "
     "slot is used",
     {foreach,
      fun start_failpool/0,
      fun kill_ppool/1,
      [fun(Name) -> ?_test(failed_run_is_an_error(Name)) end,
       fun(Name) -> ?_test(failed_run_keeps_pool(Name)) end,
       fun(Name) -> ?_test(failed_run_uses_no_slot(Name)) end,
       fun(Name) -> ?_test(failed_async_start_keeps_pool(Name)) end,
       fun(Name) -> ?_test(failed_queued_start_keeps_queue(Name)) end,
       fun(Name) -> ?_test(failed_init_leaves_siblings(Name)) end,
       fun(Name) -> ?_test(three_tuple_start_is_a_worker(Name)) end]}}.

start_failpool() ->
    application:start(ppool),
    Name = list_to_atom("failpool_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = ppool:start_pool(Name, 2, {ppool_tests, start_worker, []}),
    Name.

failed_run_is_an_error(Name) ->
    ?assertEqual({error, bad_init}, ppool:run(Name, [{error, bad_init}])),
    ?assertMatch({error, {'EXIT', {boom, _}}}, ppool:run(Name, [raise])),
    ?assertEqual({error, init_failed}, ppool:run(Name, [init_exit])),
    %% start function that does not exist with these arguments
    ?assertMatch({error, _}, ppool:run(Name, [too, many, arguments])),
    ?assertEqual({error, bad_init},
                 ppool:sync_queue(Name, [{error, bad_init}])).

failed_run_keeps_pool(Name) ->
    Serv = whereis(Name),
    {ok, Good} = ppool:run(Name, [ok]),
    [{error, _} = ppool:run(Name, [Bad])
     || Bad <- [{error, x}, raise, init_exit, [too, many]]],
    ?assertEqual(Serv, whereis(Name)),
    ?assert(is_process_alive(Good)),
    %% the pool still works
    ?assertMatch({ok, _}, ppool:run(Name, [ok])).

failed_run_uses_no_slot(Name) ->
    [{error, _} = ppool:run(Name, [{error, x}]) || _ <- lists:seq(1, 5)],
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertEqual(noalloc, ppool:run(Name, [ok])).

failed_async_start_keeps_pool(Name) ->
    Serv = whereis(Name),
    {ok, Good} = ppool:run(Name, [ok]),
    %% free slot: the cast starts the worker at once, and fails
    ok = ppool:async_queue(Name, [{error, async_bad}]),
    ok = ppool:async_queue(Name, [raise]),
    %% a call from the same process is handled after the casts
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertEqual(noalloc, ppool:run(Name, [ok])),
    ?assertEqual(Serv, whereis(Name)),
    ?assert(is_process_alive(Good)).

failed_queued_start_keeps_queue(Name) ->
    Serv = whereis(Name),
    Me = self(),
    {ok, W1} = ppool:run(Name, [ok]),
    {ok, W2} = ppool:run(Name, [ok]),
    %% queue, in this order: a sync request that fails to start, an
    %% async one that fails, and a good one
    spawn(fun() ->
              Me ! {sync_result, ppool:sync_queue(Name, [{error, qbad}])}
          end),
    wait_queue_len(Name, 1),
    ok = ppool:async_queue(Name, [{error, async_bad}]),
    wait_queue_len(Name, 2),
    ok = ppool:async_queue(Name, [{notify, Me}]),
    wait_queue_len(Name, 3),
    %% a slot frees up: the bad items are dropped, the good one runs
    W1 ! stop,
    receive {sync_result, SyncResult} ->
            ?assertEqual({error, qbad}, SyncResult)
    after 2000 -> ?assert(sync_caller_not_answered)
    end,
    receive {up, NewWorker} -> ?assert(is_process_alive(NewWorker))
    after 2000 -> ?assert(queued_good_item_never_started)
    end,
    wait_queue_len(Name, 0),
    ?assertEqual(Serv, whereis(Name)),
    ?assert(is_process_alive(W2)),
    %% both slots are in use again (W2 and the new worker)
    ?assertEqual(noalloc, ppool:run(Name, [ok])).

failed_init_leaves_siblings(Name) ->
    %% many more failures than the worker supervisor's restart
    %% intensity (5 in 3600 s), of every kind: none of them may count
    {state, _, WorkerSup, _, _, _} = ppool:status(Name),
    {ok, Good} = ppool:run(Name, [ok]),
    [{error, _} = ppool:run(Name, [Bad])
     || _ <- lists:seq(1, 4),
        Bad <- [{error, x}, raise, init_exit]],
    ?assert(is_process_alive(Good)),
    ?assert(is_process_alive(WorkerSup)),
    {state, _, WorkerSup2, _, _, _} = ppool:status(Name),
    ?assertEqual(WorkerSup, WorkerSup2).

three_tuple_start_is_a_worker(Name) ->
    %% {ok, Pid, Info} is a legal return of a start function: the
    %% worker is run and counted like any other
    {ok, Pid} = ppool:run(Name, [three]),
    ?assert(is_process_alive(Pid)),
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertEqual(noalloc, ppool:run(Name, [ok])).

%% The pool server's state is a record, which ppool:status/1 returns
%% as it is: {state, Limit, Sup, Refs, Queue, Name}.
wait_queue_len(Name, N) ->
    wait_queue_len(Name, N, 400).

wait_queue_len(Name, N, 0) ->
    ?assertEqual(N, queue_len(Name));
wait_queue_len(Name, N, Tries) ->
    case queue_len(Name) of
        N -> ok;
        _ -> timer:sleep(5), wait_queue_len(Name, N, Tries - 1)
    end.

queue_len(Name) ->
    {state, _Limit, _Sup, _Refs, Queue, _Name} = ppool:status(Name),
    queue:len(Queue).

%% Start functions for the tests above.
start_worker(ok) ->
    {ok, spawn_link(fun worker_loop/0)};
start_worker({notify, To}) ->
    {ok, Pid} = start_worker(ok),
    To ! {up, Pid},
    {ok, Pid};
start_worker({error, Reason}) ->
    {error, Reason};
start_worker(raise) ->
    erlang:error(boom);
start_worker(three) ->
    {ok, Pid} = start_worker(ok),
    {ok, Pid, info};
start_worker(init_exit) ->
    %% a linked process that dies before it reports in
    proc_lib:start_link(?MODULE, init_exit, []).

init_exit() ->
    exit(init_failed).

worker_loop() ->
    receive stop -> ok end.
