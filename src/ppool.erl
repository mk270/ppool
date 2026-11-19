% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

-module(ppool).
-moduledoc """
Public API of the ppool worker pool library.

This is the only module applications are expected to call.  The
other modules (`ppool_serv`, `ppool_sup`, `ppool_supersup` and
`ppool_worker_sup`) are internal: they implement the supervision
tree and the pool server and are documented for maintainers only.

Start the `ppool` application first (it starts the top-level
supervisor, registered as `ppool`), then create named pools with
`start_pool/3` and run work in them with `run/2`,
`sync_queue/2` or `async_queue/2`.

A worker module must export a function which starts a process
linked to its caller and returns `{ok, Pid}` (as `start_link`
functions of gen_server, gen_statem etc. do).

Derived from the ppool application in "Learn You Some Erlang for
Great Good" by Frederic Trottier-Hebert (MIT licence).
""".
-behaviour(application).
-doc "The name of a pool; also the registered name of its pool server.".
-type name() :: atom().
-doc "Module, function and leading arguments of a worker's start function.".
-type mfa_spec() :: {module(), atom(), list()}.
-doc "Reason of a failed `start_pool/3`; see there.".
-type start_error() :: {invalid_name, term()}
                     | {invalid_limit, term()}
                     | {invalid_mfa, term()}
                     | {already_started, pid()}
                     | term().
-export_type([name/0, mfa_spec/0, start_error/0]).
-export([start/2, stop/1, start_pool/3,
		 status/1,
         run/2, sync_queue/2, async_queue/2, stop_pool/1]).

-doc """
Application callback; starts the top-level supervisor.
Not for direct use: call `application:start(ppool)`.
""".
-spec start(Type, StartArgs) -> Result
              when Type      :: normal,
                   StartArgs :: term(),
                   Result    :: {ok, pid()} | ignore | {error, term()}.
start(normal, _Args) ->
    ppool_supersup:start_link().

-doc """
Application callback; does nothing.
""".
-spec stop(State) -> Result
              when State  :: term(),
                   Result :: ok.
stop(_State) ->
    ok.

-doc """
Starts a pool called `Name` that runs at most `Limit` workers
at once.  Each worker is started by calling `apply(M, F, A ++ Args)`
where `{M, F, A}` is the third argument and `Args` the list given
to `run/2`, `sync_queue/2` or `async_queue/2`.

The arguments are checked first, in this order, before anything is
started, and the first failure is returned as an error: nothing is
started or registered.

- `{error, {invalid_name, Name}}` if `Name` is not an atom;
- `{error, {invalid_limit, Limit}}` if `Limit` is not an integer
or is less than 1;
- `{error, {invalid_mfa, MFA}}` if `MFA` is not a tuple
  `{Module, Function, Args}` with atoms `Module` and `Function` and a
  list `Args`.

Otherwise returns `{ok, SupPid}` with the pid of the pool's
supervisor, or `{error, Reason}` from starting it.  A `Name` that
is already used by a pool gives `{error, {already_started, Pid}}`;
a `Name` registered by some other process gives an error whose
reason also contains `{already_started, Pid}`.  Exits with `noproc`
if the ppool application is not running.
""".
-spec start_pool(Name, Limit, MFA) -> Result
              when Name   :: name(),
                   Limit  :: pos_integer(),
                   MFA    :: mfa_spec(),
                   Result :: {ok, pid()} | {error, start_error()}.
start_pool(Name, _Limit, _MFA) when not is_atom(Name) ->
    {error, {invalid_name, Name}};
start_pool(_Name, Limit, _MFA)
  when not is_integer(Limit); Limit < 1 ->
    {error, {invalid_limit, Limit}};
start_pool(Name, Limit, MFA = {M, F, A})
  when is_atom(M), is_atom(F), is_list(A) ->
    ppool_supersup:start_pool(Name, Limit, MFA);
start_pool(_Name, _Limit, MFA) ->
    {error, {invalid_mfa, MFA}}.

-doc """
Stops the pool called `Name`, killing its running workers
(after giving them time to shut down if they trap exits) and
discarding anything queued.  Returns `ok`, or `{error, not_found}`
if there is no such pool.
""".
-spec stop_pool(Name) -> Result
              when Name   :: name(),
                   Result :: ok | {error, not_found}.
stop_pool(Name) ->
    ppool_supersup:stop_pool(Name).

-doc """
Starts a worker now if the pool has a free slot.
Returns `{ok, Pid}` with the worker's pid, or `noalloc` if the pool
is full; nothing is queued in that case.  Exits with `noproc` if
there is no pool called `Name`.  If the worker cannot be started
(the start function returns `{error, Reason}`, raises, or does not
exist for these arguments) returns `{error, Reason}`; the pool, its
running workers and its queue are not affected, and no slot is used.
(`undefined` as a pid is possible if the start function returns
`ignore`.)
""".
-spec run(Name, Args) -> Result
              when Name   :: name(),
                   Args   :: list(),
                   Result :: {ok, pid() | undefined}
                           | noalloc
                           | {error, term()}.
run(Name, Args) ->
    ppool_serv:run(Name, Args).

-doc """
Asks the pool to run a worker as soon as a slot is free,
without waiting.  Returns `ok` immediately.  Exits with `noproc` if
there is no pool called `Name`, as `run/2` does, so a mistyped
name is not mistaken for success.  The worker's pid is not reported.
If the worker cannot be started the
request is dropped and a warning is logged.
""".
-spec async_queue(Name, Args) -> Result
              when Name   :: name(),
                   Args   :: list(),
                   Result :: ok.
async_queue(Name, Args) ->
    ppool_serv:async_queue(Name, Args).

-doc """
Like `run/2`, but if the pool is full, waits (with no
timeout) in the pool's queue until a slot is free.  Returns
`{ok, Pid}` once the worker has been started.  Exits with `noproc`
if there is no pool called `Name`, or with the reason the pool
server dies if it goes away while the caller waits.  If the worker
cannot be started returns `{error, Reason}`, as `run/2` does,
and the next request in the queue is tried.
""".
-spec sync_queue(Name, Args) -> Result
              when Name   :: name(),
                   Args   :: list(),
                   Result :: {ok, pid() | undefined} | {error, term()}.
sync_queue(Name, Args) ->
    ppool_serv:sync_queue(Name, Args).

-doc """
Returns the internal state record of the pool server as a
tuple, `{state, Limit, Sup, Refs, Queue, Name}`.  Intended for
debugging only; its shape is not a stable interface.  `Limit` is the
number of free slots.  Exits with `noproc` if there is no pool.
""".
-spec status(Name) -> Result
              when Name   :: name(),
                   Result :: ppool_serv:state().
status(Name) ->
	ppool_serv:status(Name).
