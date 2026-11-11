% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

%%% API module for the pool
%% @doc Public API of the ppool worker pool library.
%%
%% This is the only module applications are expected to call.  The
%% other modules (`ppool_serv', `ppool_sup', `ppool_supersup' and
%% `ppool_worker_sup') are internal: they implement the supervision
%% tree and the pool server and are documented for maintainers only.
%%
%% Start the `ppool' application first (it starts the top-level
%% supervisor, registered as `ppool'), then create named pools with
%% {@link start_pool/3} and run work in them with {@link run/2},
%% {@link sync_queue/2} or {@link async_queue/2}.
%%
%% A worker module must export a function which starts a process
%% linked to its caller and returns `{ok, Pid}' (as `start_link'
%% functions of gen_server, gen_statem etc. do).
%%
%% Derived from the ppool application in "Learn You Some Erlang for
%% Great Good" by Frederic Trottier-Hebert (MIT licence).
%% @end
-module(ppool).
-behaviour(application).
-type name() :: atom().
%% The name of a pool; also the registered name of its pool server.
-type mfa_spec() :: {module(), atom(), list()}.
%% Module, function and leading arguments of a worker's start function.
-export_type([name/0, mfa_spec/0]).
-export([start/2, stop/1, start_pool/3,
		 status/1,
         run/2, sync_queue/2, async_queue/2, stop_pool/1]).

%% @doc Application callback; starts the top-level supervisor.
%% Not for direct use: call `application:start(ppool)'.
-spec start(normal, term()) -> {ok, pid()} | ignore | {error, term()}.
start(normal, _Args) ->
    ppool_supersup:start_link().

%% @doc Application callback; does nothing.
-spec stop(term()) -> ok.
stop(_State) ->
    ok.

%% @doc Starts a pool called `Name' that runs at most `Limit' workers
%% at once.  Each worker is started by calling `apply(M, F, A ++ Args)'
%% where `{M, F, A}' is the third argument and `Args' the list given
%% to {@link run/2}, {@link sync_queue/2} or {@link async_queue/2}.
%%
%% `Name' must be an atom and `Limit' an integer, and `Name' must not
%% be registered already by any process (including another pool).
%% Returns `{ok, SupPid}' with the pid of the pool's supervisor, or
%% `{error, Reason}' (for example when the name is taken or the
%% arguments are of the wrong type).  Exits with `noproc' if the
%% ppool application is not running, and with `function_clause' if
%% the third argument is not a 3-tuple.
%%
%% Limits of zero or less are accepted, but then no worker ever runs.
-spec start_pool(name(), integer(), mfa_spec()) ->
          {ok, pid()} | {error, term()}.
start_pool(Name, Limit, {M,F,A}) ->
    ppool_supersup:start_pool(Name, Limit, {M,F,A}).

%% @doc Stops the pool called `Name', killing its running workers
%% (after giving them time to shut down if they trap exits) and
%% discarding anything queued.  Returns `ok', or `{error, not_found}'
%% if there is no such pool.
-spec stop_pool(name()) -> ok | {error, term()}.
stop_pool(Name) ->
    ppool_supersup:stop_pool(Name).

%% @doc Starts a worker now if the pool has a free slot.
%% Returns `{ok, Pid}' with the worker's pid, or `noalloc' if the pool
%% is full; nothing is queued in that case.  Exits with `noproc' if
%% there is no pool called `Name'.  If the worker cannot be started
%% (the start function returns `{error, Reason}', raises, or does not
%% exist for these arguments) returns `{error, Reason}'; the pool, its
%% running workers and its queue are not affected, and no slot is used.
%% (`undefined' as a pid is possible if the start function returns
%% `ignore'.)
-spec run(name(), list()) ->
          {ok, pid() | undefined} | noalloc | {error, term()}.
run(Name, Args) ->
    ppool_serv:run(Name, Args).

%% @doc Asks the pool to run a worker as soon as a slot is free,
%% without waiting.  Returns `ok' immediately.  Exits with `noproc' if
%% there is no pool called `Name', as {@link run/2} does, so a mistyped
%% name is not mistaken for success.  The worker's pid is not reported.
%% If the worker cannot be started the
%% request is dropped and a warning is logged.
-spec async_queue(name(), list()) -> ok.
async_queue(Name, Args) ->
    ppool_serv:async_queue(Name, Args).

%% @doc Like {@link run/2}, but if the pool is full, waits (with no
%% timeout) in the pool's queue until a slot is free.  Returns
%% `{ok, Pid}' once the worker has been started.  Exits with `noproc'
%% if there is no pool called `Name', or with the reason the pool
%% server dies if it goes away while the caller waits.  If the worker
%% cannot be started returns `{error, Reason}', as {@link run/2} does,
%% and the next request in the queue is tried.
-spec sync_queue(name(), list()) ->
          {ok, pid() | undefined} | {error, term()}.
sync_queue(Name, Args) ->
    ppool_serv:sync_queue(Name, Args).

%% @doc Returns the internal state record of the pool server as a
%% tuple, `{state, Limit, Sup, Refs, Queue, Name}'.  Intended for
%% debugging only; its shape is not a stable interface.  `Limit' is the
%% number of free slots.  Exits with `noproc' if there is no pool.
-spec status(name()) -> tuple().
status(Name) ->
	ppool_serv:status(Name).
