% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

%% @doc Internal: the top-level supervisor, registered as `ppool'.
%% Strategy `one_for_one' (intensity 6 in 3000 ms); it has one
%% permanent child (a `ppool_sup') per pool.
%% @end
-module(ppool_supersup).
-behaviour(supervisor).
-export([start_link/0, start_pool/3, stop_pool/1]).
-export([init/1]).
-export([stop/0]).

%% @doc Starts the top-level supervisor and registers it as `ppool'.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ppool}, ?MODULE, []).

%% @doc Kills the top-level supervisor, and with it every pool.
%% Returns `true' if it was running, `ok' otherwise.  Not used by the
%% library itself.
-spec stop() -> ok | true.
%% technically, a supervisor can not be killed in an easy way.
%% Let's do it brutally!
stop() ->
    case whereis(ppool) of
        P when is_pid(P) ->
            exit(P, kill);
        _ -> ok
    end.

%% @doc See `ppool:start_pool/3'.
-spec start_pool(atom(), integer(), {module(), atom(), list()}) ->
          {ok, pid()} | {error, term()}.
start_pool(Name, Limit, MFA) ->
    ChildSpec = {Name,
                 {ppool_sup, start_link, [Name, Limit, MFA]},
                  permanent, 10500, supervisor, [ppool_sup]},
    supervisor:start_child(ppool, ChildSpec).

%% @doc See `ppool:stop_pool/1'.
-spec stop_pool(atom()) -> ok | {error, term()}.
stop_pool(Name) ->
    supervisor:terminate_child(ppool, Name),
    supervisor:delete_child(ppool, Name).

init([]) ->
    MaxRestart = 6,
    MaxTime = 3000,
    {ok, {{one_for_one, MaxRestart, MaxTime}, []}}.
