ppool
=====

ppool is a lightweight worker pool for Erlang, originally published as
[didactic code](https://learnyousomeerlang.com/building-applications-with-otp#a-pool-of-processes)
in [Learn You Some Erlang](https://learnyousomeerlang.com/) by
Frédéric Trottier-Hébert.

Copyright (c) 2009 Frédéric Trottier-Hébert; available under the terms
of the MIT Licence.

Contents: [Overview](#overview), [Installing](#installing),
[Quick start](#quick-start), [API](#api), [Workers](#writing-a-worker),
[Supervision](#supervision-and-failures), [Queue](#the-queue),
[Caveats](#limits-and-caveats), [Development](#development).

Overview
========

This library is the "ppool" application from the chapter "Building
applications with OTP" of the book Learn You Some Erlang for Great Good
(link above). The code is kept close to the book's, and is small enough
to read in one sitting: five modules, about 250 lines.

A pool has a name and a limit N. At most N workers run at once. A
request to run a worker is either started immediately, refused, or (if
you choose a queueing call) held in a first-in first-out queue until a
running worker exits.

Structure of the supervision tree:

    ppool (application)
      ppool_supersup   registered as `ppool'; one_for_one
        ppool_sup      one per pool; one_for_all
          ppool_serv   the pool server, registered under the pool name
          ppool_worker_sup   simple_one_for_one; parent of the workers
            worker, worker, ...

The pool server counts free slots, monitors every worker it started,
and holds the queue. When a monitored worker goes down (for any reason)
it starts the next queued request, or frees the slot if the queue is
empty.

The public API is the module `ppool`. The other modules are internal.

Installing
==========

ppool 1.1.1 is on hex.pm (https://hex.pm/packages/ppool). With rebar3:

    {deps, [{ppool, "1.1.1"}]}.

or from git (the repository is at https://github.com/mk270/ppool):

    {deps, [{ppool, {git, "https://github.com/mk270/ppool.git",
                     {branch, "master"}}}]}.

Add `ppool` to the `applications` list of your application, or start it
yourself with `application:ensure_all_started(ppool)`. It depends only
on kernel and stdlib.

Quick start
===========

    1> ppool:start_pool(nagger, 2, {ppool_nagger, start_link, []}).
    {ok,<0.35.0>}
    2> ppool:run(nagger, ["finish the chapter!", 10000, 10, self()]).
    {ok,<0.39.0>}

(Start the application first with `application:start(ppool)`.) The
example worker `ppool_nagger` lives in the `test/` directory of this
repository, so it is only available when working on ppool itself; it
is a gen_server that sends `{self(), Task}` to the given pid every
`Delay` ms, `Max` times (or forever if `Max` is `infinity`). After the
call above, the shell receives that message ten times at ten second
intervals.

API
===

All functions are in the module `ppool`. Pool names are atoms. In the
examples below `Pid` values are of course different on each run.

start_pool(Name, Limit, {M, F, A})
----------------------------------

Starts a pool. `Name` is an atom; it becomes the registered name of the
pool server, so it must not be registered already by any process.
`Limit` is an integer. `{M, F, A}` says how to start a worker: each
worker is started with `apply(M, F, A ++ Args)`, where `Args` is the
list given to `run/2` and friends. So `A` holds the arguments common to
all workers and `Args` the per-call ones.

Returns `{ok, SupPid}` (the pid of the pool's supervisor) or
`{error, Reason}`.

    1> ppool:start_pool(nagger, 2, {ppool_nagger, start_link, []}).
    {ok,<0.87.0>}
    2> ppool:start_pool(nagger, 2, {ppool_nagger, start_link, []}).
    {error,{already_started,<0.87.0>}}

Error cases:

* A name already registered by some other process (for example `ppool`
  or `init`) gives `{error, {{shutdown, {failed_to_start_child, serv,
  {already_started, Pid}}}, ChildSpec}}`. A name already used by a
  pool gives `{error, {already_started, SupPid}}`.
* A `Name` that is not an atom, or a `Limit` that is not an integer
  (for example `1.5` or `infinity`), gives an `{error, ...}` whose
  reason contains a `function_clause` exit; a supervisor crash report
  is also logged.
* A third argument that is not a 3-tuple makes the call itself exit
  with `function_clause`.
* If the ppool application is not running, the call exits with
  `noproc`.
* Zero and negative limits are accepted, but such a pool never runs
  anything (see Caveats).

stop_pool(Name)
---------------

Stops the pool: its supervisor is shut down, which shuts down the pool
server and all running workers (they are asked to stop, and killed if
they do not stop within 5 seconds). The queue is discarded. Returns
`ok`, or `{error, not_found}` if there is no such pool (so a second
call returns `{error, not_found}`).

    1> ppool:stop_pool(nagger).
    ok
    2> ppool:stop_pool(nagger).
    {error,not_found}

Callers blocked in `sync_queue/2` when the pool is stopped exit with
reason `shutdown`.

run(Name, Args)
---------------

Starts a worker immediately if the pool has a free slot. Returns
`{ok, Pid}` with the worker's pid, or the atom `noalloc` if the pool is
full. Nothing is queued on `noalloc`. If the worker cannot be started
it returns `{error, Reason}` (see below).

    1> ppool:run(nagger, [hi, 100, 2, self()]).
    {ok,<0.90.0>}
    2> flush().
    Shell got {<0.90.0>,hi}
    Shell got {<0.90.0>,hi}
    3> ppool:run(nagger, [a, infinity, infinity, self()]).
    {ok,<0.94.0>}
    4> ppool:run(nagger, [b, infinity, infinity, self()]).
    {ok,<0.95.0>}
    5> ppool:run(nagger, [c, 10, 1, self()]).
    noalloc

Error cases: if no pool has that name the caller exits with
`{noproc, {gen_server, call, [Name, {run, Args}]}}`. If the worker's
start function fails (returns `{error, Reason}`, raises, or does not
exist, for example because `Args` has the wrong length) the call
returns `{error, Reason}`, a warning is logged, and no slot is used.
The pool, its running workers and its queue are not affected.

    1> ppool:run(nagger, [too, many, arguments, here, now]).
    {error,{'EXIT',{undef,[{ppool_nagger,start_link,
                               [too,many,arguments,here,now],
                               []},
                           {supervisor,do_start_child_i,3,
                                       [{file,"supervisor.erl"},...]},
                           ...]}}}

The call has the default 5 second gen_server timeout.

async_queue(Name, Args)
-----------------------

Runs a worker as soon as there is a free slot: immediately if there is
one, otherwise after waiting in the queue. Returns `ok` at once and
never tells you the worker's pid.

    1> ppool:async_queue(nagger, [q1, 10, 1, self()]).
    ok

This is a cast, but the pool name is checked first: if no pool has
that name the caller exits with `{noproc, {gen_server, cast, [Name,
{async, Args}]}}`, as for `run/2`, rather than the request being lost
silently. (A pool that dies just after the check still loses the
request.) If the worker cannot be
started, nobody is told: the request is dropped and a warning is
logged by the pool server. A free slot is not used up by this.

sync_queue(Name, Args)
----------------------

Like `run/2`, but when the pool is full the caller blocks, with no
timeout, until its request reaches the front of the queue and a worker
has been started for it. Returns `{ok, Pid}`, or `{error, Reason}` if
the worker could not be started, as for `run/2`; the pool then goes on
to the next queued request.

    1> ppool:sync_queue(nagger, [q2, 10, 1, self()]).
    {ok,<0.101.0>}      %% after a slot became free

Error cases: `noproc` exit if there is no such pool; if the pool server
dies while you wait, you exit with the reason it died with (for
example `shutdown` after `stop_pool/1`). Because the timeout is
`infinity`, wrap the call in your own timeout if you need one, for
instance by calling it from a spawned process.

status(Name)
------------

Returns the state of the pool server as a raw record tuple
`{state, Limit, Sup, Refs, Queue, Name}`, for debugging. `Limit` is the
number of free slots (limit minus running workers), `Sup` the pid of
the worker supervisor, `Refs` a `gb_sets` of monitor references and
`Queue` a `queue` of waiting requests. This shape is not a stable
interface. Exits with `noproc` if the pool does not exist.

    1> ppool:status(nagger).
    {state,0,<0.89.0>,{2,{#Ref<...>,nil,{#Ref<...>,nil,nil}}},
           {[[q1,10,1,<0.10.0>]],[]},
           nagger}

start/2 and stop/1
------------------

Application callbacks. Use `application:start(ppool)` instead.

Writing a worker
================

A worker is started by `apply(M, F, A ++ Args)` and the function must
behave like an OTP `start_link`: it must start a process linked to the
caller and return `{ok, Pid}`.

Why: the caller is the worker supervisor (`ppool_worker_sup`), which
needs the link to supervise the process and to shut it down when the
pool stops. The pool server additionally monitors the returned pid to
learn when the worker is finished. Each worker's exit, normal or not,
frees its slot.

What other return values do:

* `{error, Reason}` or an exception: the worker is not started. `run/2`
  and `sync_queue/2` return `{error, Reason}` (for an exception,
  `Reason` is `{'EXIT', Why}`); `async_queue/2` drops the request. In
  every case a warning is logged, the pool server carries on, and no
  slot is used.
* `{ok, Pid, Info}` (three-tuple): treated as `{ok, Pid}`; `Info` is
  ignored.
* `ignore`: `run/2` returns `{ok, undefined}`, and the slot is freed
  again immediately (monitoring `undefined` reports `noproc`).

The example from `test/ppool_nagger.erl`:

    start_link(Task, Delay, Max, SendTo) ->
        gen_server:start_link(?MODULE, {Task, Delay, Max, SendTo}, []).

A pool started with `{ppool_nagger, start_link, []}` calls it as
`ppool_nagger:start_link(Task, Delay, Max, SendTo)` for
`ppool:run(Pool, [Task, Delay, Max, SendTo])`. With `A = [pre]` the call
would be `start_link(pre, Task, Delay, ...)`:

    1> ppool:start_pool(o, 1, {ppool_nagger, start_link, [pre]}).
    2> ppool:run(o, [1, 2, self()]).     %% start_link(pre, 1, 2, Self)
    {ok,<0.92.0>}

Workers are `temporary`: they are never restarted. Shutdown timeout is
5000 ms. If a worker traps exits it still gets a proper shutdown
request when the pool is stopped.

Supervision and failures
========================

Worker exits (normal or crash) are not restarted. The pool server sees
the 'DOWN' message, then starts the next queued request or frees the
slot. Tested by killing a running worker with `exit(Pid, kill)`: a
queued request started in its place and the pool's slot count stayed
correct.

A worker that fails to start does not count as a failure of anything:
it does not disturb the running workers, the queue, the pool server or
the worker supervisor (tested with many consecutive failures of every
kind, well beyond the supervisor's restart intensity).

If the pool server crashes (or is killed) its pool supervisor
(`one_for_all`, at most 1 restart in 3 seconds) restarts everything in
that pool. Consequences, verified:

* all running workers of that pool are killed (their supervisor is
  restarted too);
* the queue is lost, silently. Callers blocked in `sync_queue/2` get an
  exit, and `async_queue/2` requests are forgotten;
* the pool comes back with the same name and a full set of free slots;
* a new pool-server pid is registered, so for a short moment calls to
  the name may fail with `noproc`.

If the pool supervisor itself fails (a second crash within 3 seconds
exceeds its restart intensity) the top-level supervisor restarts it,
again giving an empty pool. The top-level supervisor allows 6 restarts
in 3 seconds. If it dies, the application stops and all pools go with
it. Pools are not persistent: after a restart of the application there
are no pools and you must call `start_pool/3` again.

Pools are independent: a crash in one does not affect the others.

The queue
=========

The queue is strictly first-in first-out, and `sync_queue/2` and
`async_queue/2` requests share it. Checked with a pool of limit 1: a
running worker, then `async r1`, `sync r2`, `async r3` were started in
that order r1, r2, r3.

A request is only taken from the queue when a worker goes down; the
pool never reorders or expires entries. The queue is held in the pool
server's memory and is unbounded: 100000 queued requests were accepted
without trouble, and nothing limits it. There is no back-pressure on
`async_queue/2`, and no way to cancel a queued request or inspect it
other than `status/1`. `run/2` never looks at the queue: it returns
`noalloc` when the pool is full even if requests are queued.

Limits and caveats
==================

* Pool names are atoms and registered names, so they share the
  registered-name namespace with everything on the node (and the atom
  table is finite). Do not create pools from untrusted input.
* A pool name equal to `ppool` or to any other registered process fails
  to start.
* Queue is unbounded (above) and lives in one process.
* A limit of zero (or less) is accepted but is useless: `run/2`
  returns `noalloc`, and `async_queue/2` and `sync_queue/2` queue the
  request forever, as slots never free up.
* `Limit` is fixed when the pool is created; there is no way to change
  it.
* There is no way to wait for a worker to finish, other than monitoring
  it yourself using the pid from `run/2` or `sync_queue/2`.
  `async_queue/2` gives you no pid at all.
* The pool server logs unexpected plain messages with `io:format`.
* `ppool_nagger` is test code; it is not part of the released package.
* This is didactic code, and the original is kept as it was, with one
  deliberate behaviour change: a worker that fails to start is
  reported to the caller (or logged and dropped, for `async_queue/2`
  and for queued requests) instead of crashing the pool server and
  with it every running worker and the queue. The success path is
  untouched; everything else is comments, specs, documentation and
  tests.

Development
===========

You need Erlang/OTP and rebar3.

    rebar3 compile
    rebar3 eunit       # 27 tests
    rebar3 dialyzer
    rebar3 edoc        # writes doc/index.html

The API documentation is generated from edoc comments in `src/`. The
test suite starts the application and uses `ppool_nagger`. (It uses
`now/0`, which gives a deprecation warning on current OTP.)

Licence and attribution
=======================

MIT licence; see LICENSE.txt. The code derives from the ppool
application of Learn You Some Erlang for Great Good by Frederic
Trottier-Hebert (https://learnyousomeerlang.com/), chapter "Building
applications with OTP".
