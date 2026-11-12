% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

-module(ppool_tests).
-include_lib("eunit/include/eunit.hrl").
-export([start_worker/1, init_exit/0, start_any/3]).

%%% All Test Fixtures
start_test_() ->
    {"It should be possible to start a pool server and give it a name",
     {setup,
      fun find_unique_name/0,
      fun(Name) ->
        [?_test(start_and_test_name(Name))]
      end}}.

mfa_test_() ->
    {"A pool process can be allocated which will be ordered "
     "to run an MFA call determined at start time, with arguments "
     "provided at call time",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun(Name) ->
        [?_test(pool_run_mfa(Name))]
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
        [?_test(pool_run_alloc(Name)),
         ?_test(pool_run_noalloc(Name))]
      end}
    }.

realloc_test_() ->
    {"When an allocated process dies, "
     "A new one can be allocated to replace it.",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun(Name) ->
        [?_test(pool_run_realloc(Name))]
      end}
    }.

queue_test_() ->
    {"The queue function can be used to run the function as soon as possible. "
     "If no space is available, the worker call is added to the queue.",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun(Name) -> ?_test(test_sync_queue(Name)) end}
    }.

async_queue_test_() ->
    {"An async queue item waits for a free slot and then runs",
     {setup,
      fun start_failpool/0,
      fun kill_ppool/1,
      fun(Name) -> ?_test(test_async_queue(Name)) end}}.

supervision_test_() ->
    {"The ppool will never restart a dead child, but all children (OTP "
     "compliant) will be shut down when closing the pool, even if they "
     "are trapping exits",
     {setup,
      fun find_unique_name/0,
      fun(Name) -> ?_test(test_supervision(Name)) end}}.
    
auth_test_() ->
    {"The ppool should only dequeue tasks after receiving a down signal "
     "from a worker and nobody else",
     {setup,
      fun start_ppool/0,
      fun kill_ppool/1,
      fun(Name) -> ?_test(test_auth_dealloc(Name)) end}}.

%%% Setups/teardowns
find_unique_name() ->
    application:start(ppool),
    Name = list_to_atom("pool_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    ?assertEqual(undefined, whereis(Name)),
    Name.

start_ppool() ->
    Name = find_unique_name(),
    ppool:start_pool(Name, 2, {ppool_nagger, start_link, []}),
    Name.

kill_ppool(Name) ->
    ppool:stop_pool(Name).
    
%%% Actual tests
%%%
%%% The workers are ppool_nagger processes: each sends {self(), Task}
%%% to the test after Delay ms and then, with Max = 1, stops.  The
%%% tests wait for those messages and for the workers' exits instead
%%% of sleeping, so they do not depend on how fast the machine is.
start_and_test_name(Name) ->
    ppool:start_pool(Name, 1, {ppool_nagger, start_link, []}),
    A = whereis(Name),
    ppool:stop_pool(Name),
    B = whereis(Name),
    ?assert(undefined =/= A),
    ?assertEqual(undefined, B).

pool_run_mfa(Name) ->
    ppool:run(Name, [i_am_running, 1, 1, self()]),
    X = receive
        {_Pid, i_am_running} -> ok
    after 3000 ->
        timeout
    end,
    ?assertEqual(ok, X).

pool_run_alloc(Name) ->
    {ok, Pid} = ppool:run(Name, [i_am_running, 1, 1, self()]),
    X = receive
        {Pid, i_am_running} -> ok
    after 3000 ->
        timeout
    end,
    ?assert(is_pid(Pid)),
    ?assertEqual(ok, X).

pool_run_noalloc(Name) ->
    %% Init function should have set the limit to 2
    ppool:run(Name, [i_am_running, 10000, 1, self()]),
    ppool:run(Name, [i_am_running, 10000, 1, self()]),
    X = ppool:run(Name, [i_am_running, 1, 1, self()]),
    ?assertEqual(noalloc, X).

pool_run_realloc(Name) ->
    %% Init function should have set the limit to 2
    {ok, A} = ppool:run(Name, [i_am_running, 20, 1, self()]),
    {ok, B} = ppool:run(Name, [i_am_running, 20, 1, self()]),
    ?assertEqual(noalloc, ppool:run(Name, [i_am_running, 1, 1, self()])),
    %% both workers announce themselves and exit, freeing both slots
    ok = await_msg(A, i_am_running),
    ok = await_msg(B, i_am_running),
    ok = await_exit(A),
    ok = await_exit(B),
    wait_free(Name, 2),
    {ok, Pid} = ppool:run(Name, [i_am_running, 1, 1, self()]),
    ok = await_msg(Pid, i_am_running),
    ?assert(is_pid(Pid)),
    ?assertEqual([], flush()).

test_async_queue(Name) ->
    %% Still two elements max!  The workers here are not naggers: they
    %% run until told to stop, and tell us when they are started.
    Me = self(),
    ok = ppool:async_queue(Name, [{notify, Me}]),
    ok = ppool:async_queue(Name, [{notify, Me}]),
    W1 = await_up(),
    _W2 = await_up(),
    noalloc = ppool:run(Name, [ok]),
    ok = ppool:async_queue(Name, [{notify, Me}]),
    %% the third waits in the queue until a slot is freed
    wait_queue_len(Name, 1),
    ?assertEqual([], flush()),
    W1 ! stop,
    W3 = await_up(),
    ?assert(is_pid(W3)),
    wait_queue_len(Name, 0),
    ?assertEqual([], flush()).

test_sync_queue(Name) ->
    %% Hell yase, two max
    Me = self(),
    {ok, Pid} = ppool:sync_queue(Name, [i_am_running, 20, 1, Me]),
    ok = ppool:async_queue(Name, [i_am_running, 20, 1, Me]),
    ok = ppool:async_queue(Name, [i_am_running, 20, 1, Me]),
    %% blocks until one of the others is done
    {ok, Pid2} = ppool:sync_queue(Name, [i_am_running, 10, 1, Me]),
    L = [await_any(i_am_running) || _ <- lists:seq(1, 4)],
    ?assert(is_pid(Pid)),
    ?assert(is_pid(Pid2)),
    ?assertMatch([_, _, _, _], L),
    ?assertEqual([], flush()).

test_supervision(Name) ->
    ppool:start_pool(Name, 1, {ppool_nagger, start_link, []}),
    {ok, Pid} = ppool:run(Name, [sup, 10000, 100, self()]),
    ppool:stop_pool(Name),
    %% stop_pool/1 returns once the pool's whole tree is down
    ?assertEqual(undefined, process_info(Pid)).

test_auth_dealloc(Name) ->
    %% Hell yase, two max
    Me = self(),
    {ok, W} = ppool:sync_queue(Name, [i_am_running, 20, 1, Me]),
    ok = ppool:async_queue(Name, [i_am_running, 10000, 1, Me]),
    ok = ppool:async_queue(Name, [i_am_running, 10000, 1, Me]),
    ok = ppool:async_queue(Name, [i_am_running, 1, 1, Me]),
    wait_queue_len(Name, 2),
    %% W is done: its real DOWN lets the first queued item start
    ok = await_msg(W, i_am_running),
    wait_queue_len(Name, 1),
    %% DOWN messages from anybody else are ignored; the call is
    %% handled after them, as they come from the same process
    Name ! {'DOWN', make_ref(), process, self(), normal},
    Name ! {'DOWN', make_ref(), process, self(), normal},
    Name ! {'DOWN', make_ref(), process, self(), normal},
    ?assertEqual(1, queue_len(Name)),
    ?assertEqual([], flush()).

%%% Waiting helpers.

%% The next {Pid, Msg} from a nagger (or timeout).
await_msg(Pid, Msg) ->
    receive {Pid, Msg} -> ok
    after 3000 -> timeout
    end.

await_any(Msg) ->
    receive {Pid, Msg} -> Pid
    after 3000 -> timeout
    end.

%% The next worker started by start_worker({notify, To}).
await_up() ->
    receive {up, Pid} -> Pid
    after 3000 -> timeout
    end.

%% Wait for a process to be gone.
await_exit(Pid) ->
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 3000 -> timeout
    end.

%% Wait until the pool server has N free slots (the first field of its
%% state); a worker's exit reaches the server a moment after its
%% other monitors.
wait_free(Name, N) ->
    wait_until(fun() ->
                   {state, Free, _, _, _, _} = ppool:status(Name),
                   Free =:= N
               end).

wait_until(Fun) ->
    wait_until(Fun, 400).

wait_until(Fun, 0) ->
    ?assert(Fun());
wait_until(Fun, Tries) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(5), wait_until(Fun, Tries - 1)
    end.

flush() ->
    receive
        X -> [X|flush()]
    after 0 ->
        []
    end.

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
    start_ctlpool(2).

%% A pool of start_worker/1 workers, which run until sent `stop'.
start_ctlpool(Limit) ->
    application:start(ppool),
    Name = list_to_atom("failpool_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = ppool:start_pool(Name, Limit, {ppool_tests, start_worker, []}),
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
start_worker({started, To, Tag}) ->
    {ok, Pid} = start_worker(ok),
    To ! {started, Tag, Pid},
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

%%% Slot accounting, duplicate names, stopping and crashing pools.
%%%
%%% These pin the behaviour as it is.  Each test has its own pool of
%%% start_worker/1 workers (limit 2 unless it says otherwise).
slot_test_() ->
    {"A worker that dies abnormally frees its slot, and the next "
     "queued item runs in it",
     {foreach,
      fun start_failpool/0,
      fun kill_ppool/1,
      [fun(Name) -> ?_test(abnormal_exit_frees_slot(Name)) end]}}.

abnormal_exit_frees_slot(Name) ->
    Me = self(),
    {ok, W1} = ppool:run(Name, [ok]),
    {ok, W2} = ppool:run(Name, [ok]),
    ?assertEqual(noalloc, ppool:run(Name, [ok])),
    ok = ppool:async_queue(Name, [{notify, Me}]),
    wait_queue_len(Name, 1),
    exit(W1, kill),
    %% the queued item takes over the slot
    W3 = await_up(),
    ?assert(is_process_alive(W3)),
    wait_queue_len(Name, 0),
    ?assertEqual(noalloc, ppool:run(Name, [ok])),
    %% with an empty queue the slots are simply given back
    exit(W2, crash),
    exit(W3, kill),
    ok = await_exit(W2),
    ok = await_exit(W3),
    wait_free(Name, 2),
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertEqual(noalloc, ppool:run(Name, [ok])).

duplicate_name_test_() ->
    {"A second pool with the name of a live pool is refused and the "
     "first pool is not affected",
     {setup,
      fun start_failpool/0,
      fun kill_ppool/1,
      fun(Name) -> ?_test(duplicate_pool_name(Name)) end}}.

duplicate_pool_name(Name) ->
    Serv = whereis(Name),
    {ok, W} = ppool:run(Name, [ok]),
    MFA = {ppool_tests, start_worker, []},
    ?assertMatch({error, {already_started, _}},
                 ppool:start_pool(Name, 5, MFA)),
    ?assertEqual(Serv, whereis(Name)),
    ?assert(is_process_alive(W)),
    %% still the first pool: limit 2, one slot in use
    ?assertMatch({state, 1, _, _, _, Name}, ppool:status(Name)),
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertEqual(noalloc, ppool:run(Name, [ok])).

stop_queued_test_() ->
    {"Items still queued when the pool is stopped are dropped: an "
     "async item never runs, a sync_queue caller exits",
     {setup,
      fun start_failpool/0,
      %% the pool is stopped by the test
      fun(_Name) -> ok end,
      fun(Name) -> ?_test(stop_pool_with_queue(Name)) end}}.

stop_pool_with_queue(Name) ->
    Me = self(),
    {ok, W1} = ppool:run(Name, [ok]),
    {ok, W2} = ppool:run(Name, [ok]),
    ok = ppool:async_queue(Name, [{notify, Me}]),
    spawn(fun() ->
              R = try ppool:sync_queue(Name, [{notify, Me}])
                  catch exit:Reason -> {exit, Reason}
                  end,
              Me ! {sync_result, R}
          end),
    wait_queue_len(Name, 2),
    ?assertEqual(ok, ppool:stop_pool(Name)),
    ?assertEqual(undefined, whereis(Name)),
    ?assertEqual(undefined, process_info(W1)),
    ?assertEqual(undefined, process_info(W2)),
    %% the sync caller is told by an exit, as for any dead pool
    receive {sync_result, {exit, {shutdown, _}}} -> ok
    after 3000 -> ?assert(sync_caller_not_answered)
    end,
    %% pinned: nothing tells the async item's sender; it never runs
    receive {up, _} -> ?assert(queued_item_ran_after_stop)
    after 100 -> ok
    end,
    ?assertEqual([], flush()).

fifo_test_() ->
    {"Queued sync and async items are started in the order they were "
     "queued",
     {setup,
      fun() -> start_ctlpool(1) end,
      fun kill_ppool/1,
      fun(Name) -> ?_test(fifo_across_kinds(Name)) end}}.

fifo_across_kinds(Name) ->
    Me = self(),
    {ok, First} = ppool:run(Name, [ok]),
    Kinds = [sync, async, sync, async, async, sync],
    lists:foldl(
      fun(Kind, N) ->
              item(Kind, Name, Me, N),
              wait_queue_len(Name, N),
              N + 1
      end, 1, Kinds),
    %% free the slot over and over; each queued item starts in turn
    First ! stop,
    Order = [begin
                 {Tag, W} = await_started(),
                 W ! stop,
                 Tag
             end || _ <- Kinds],
    ?assertEqual(lists:seq(1, length(Kinds)), Order),
    wait_queue_len(Name, 0),
    %% the sync callers got their pids
    SyncTags = [N || {N, sync} <- lists:zip(lists:seq(1, 6), Kinds)],
    [receive {sync_result, N, {ok, P}} -> ?assert(is_pid(P))
     after 3000 -> ?assert(sync_caller_not_answered)
     end || N <- SyncTags].

%% Queue an item for Name; Tag is reported as {started, Tag, Pid}.
item(sync, Name, Me, Tag) ->
    spawn(fun() ->
              R = ppool:sync_queue(Name, [{started, Me, Tag}]),
              Me ! {sync_result, Tag, R}
          end);
item(async, Name, Me, Tag) ->
    ok = ppool:async_queue(Name, [{started, Me, Tag}]).

await_started() ->
    receive {started, Tag, Pid} -> {Tag, Pid}
    after 3000 -> {timeout, self()}
    end.

crash_test_() ->
    {"When the pool server is killed, the pool restarts with a fresh "
     "server: the limit is restored, the queue is empty and the "
     "running workers are dead",
     {setup,
      fun start_failpool/0,
      fun kill_ppool/1,
      fun(Name) -> ?_test(restart_after_server_crash(Name)) end}}.

restart_after_server_crash(Name) ->
    Me = self(),
    Serv = whereis(Name),
    {state, 2, Sup, _, _, _} = ppool:status(Name),
    {ok, W1} = ppool:run(Name, [ok]),
    {ok, W2} = ppool:run(Name, [ok]),
    ok = ppool:async_queue(Name, [{notify, Me}]),
    wait_queue_len(Name, 1),
    exit(Serv, kill),
    ok = await_exit(W1),
    ok = await_exit(W2),
    %% the supervisor starts a new server under the same name
    wait_until(fun() ->
                   case whereis(Name) of
                       undefined -> false;
                       Serv -> false;
                       _New -> true
                   end
               end),
    {state, 2, Sup2, Refs, Queue, Name} = ppool:status(Name),
    ?assert(Sup2 =/= Sup),
    ?assertEqual(0, gb_sets:size(Refs)),
    ?assert(queue:is_empty(Queue)),
    %% pinned: the queued async item is lost without notice
    receive {up, _} -> ?assert(queued_item_ran_after_crash)
    after 100 -> ok
    end,
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertMatch({ok, _}, ppool:run(Name, [ok])),
    ?assertEqual(noalloc, ppool:run(Name, [ok])).

%%% Front-door argument checks of ppool:start_pool/3.
%%%
%%% The wrong-typed calls go through start_any/3 (called with apply/3),
%%% so that dialyzer does not see a deliberate spec violation.
-spec start_any(term(), term(), term()) -> term().
start_any(Name, Limit, MFA) ->
    ppool:start_pool(Name, Limit, MFA).

try_start(Name, Limit, MFA) ->
    apply(?MODULE, start_any, [Name, Limit, MFA]).

pool_children() ->
    lists:sort(supervisor:which_children(ppool)).

validation_test_() ->
    {"Bad arguments to start_pool/3 are returned as errors, the first "
     "failure in the order name, limit, mfa; nothing is started or "
     "registered",
     {setup,
      fun find_unique_name/0,
      fun(Name) ->
        [?_test(invalid_names(Name)),
         ?_test(invalid_limits(Name)),
         ?_test(invalid_mfas(Name)),
         ?_test(check_order(Name)),
         ?_test(rejection_starts_nothing(Name)),
         ?_test(valid_start_still_works(Name))]
      end}}.

invalid_names(_Name) ->
    MFA = {ppool_tests, start_worker, []},
    ?assertEqual({error, {invalid_name, "pool"}},
                 try_start("pool", 1, MFA)),
    ?assertEqual({error, {invalid_name, <<"pool">>}},
                 try_start(<<"pool">>, 1, MFA)),
    ?assertEqual({error, {invalid_name, {a, b}}},
                 try_start({a, b}, 1, MFA)),
    ?assertEqual({error, {invalid_name, 42}}, try_start(42, 1, MFA)).

invalid_limits(Name) ->
    MFA = {ppool_tests, start_worker, []},
    lists:foreach(
      fun(L) ->
          ?assertEqual({error, {invalid_limit, L}},
                       try_start(Name, L, MFA))
      end,
      [0, -1, -100, 1.5, 2.0, infinity, "2", {2}]).

invalid_mfas(Name) ->
    lists:foreach(
      fun(MFA) ->
          ?assertEqual({error, {invalid_mfa, MFA}},
                       try_start(Name, 1, MFA))
      end,
      [{ppool_tests, start_worker},
       {ppool_tests, start_worker, [], extra},
       {"ppool_tests", start_worker, []},
       {ppool_tests, "start_worker", []},
       {ppool_tests, start_worker, not_a_list},
       {ppool_tests, start_worker, {}},
       ppool_tests,
       []]).

check_order(Name) ->
    MFA = {ppool_tests, start_worker, []},
    %% all three bad: the name is reported
    ?assertEqual({error, {invalid_name, "p"}},
                 try_start("p", 0, bad)),
    %% limit and MFA bad: the limit is reported
    ?assertEqual({error, {invalid_limit, 0}},
                 try_start(Name, 0, bad)),
    ?assertEqual({error, {invalid_name, "p"}},
                 try_start("p", 1, bad)),
    ?assertEqual({error, {invalid_name, "p"}},
                 try_start("p", 0, MFA)),
    %% a bad name is reported even when the name is registered
    ?assertEqual({error, {invalid_limit, 0}},
                 try_start(ppool, 0, MFA)).

rejection_starts_nothing(Name) ->
    MFA = {ppool_tests, start_worker, []},
    Before = pool_children(),
    Registered = lists:sort(registered()),
    try_start(Name, 0, MFA),
    try_start(Name, -1, MFA),
    try_start(Name, 1, {ppool_tests, start_worker}),
    try_start("x", 1, MFA),
    ?assertEqual(undefined, whereis(Name)),
    ?assertEqual(Before, pool_children()),
    ?assertEqual(Registered, lists:sort(registered())).

valid_start_still_works(Name) ->
    MFA = {ppool_tests, start_worker, []},
    Before = length(pool_children()),
    ?assertMatch({ok, _}, ppool:start_pool(Name, 1, MFA)),
    try
        ?assert(is_pid(whereis(Name))),
        ?assertEqual(Before + 1, length(pool_children())),
        ?assertMatch({error, {already_started, _}},
                     ppool:start_pool(Name, 1, MFA)),
        ?assertMatch({ok, _}, ppool:run(Name, [ok]))
    after
        ppool:stop_pool(Name)
    end,
    ?assertEqual(undefined, whereis(Name)),
    %% a limit of one and a MFA with extra start arguments are valid
    ?assertMatch({ok, _},
                 ppool:start_pool(Name, 1, {ppool_tests, start_worker,
                                            [ok]})),
    ppool:stop_pool(Name).
