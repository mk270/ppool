% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

%% @doc Internal: supervisor of the workers of one pool.  A
%% `simple_one_for_one' supervisor whose children are `temporary'
%% (never restarted) and are started with `apply(M, F, A ++ Args)'.
%% @end
-module(ppool_worker_sup).
-export([start_link/1, init/1]).
-behaviour(supervisor).

%% @doc Starts the worker supervisor for the given `{M, F, A}'.
-spec start_link(MFA) -> Result
              when MFA    :: {module(), atom(), list()},
                   Result :: {ok, pid()} | ignore | {error, term()}.
start_link(MFA = {_,_,_}) ->
    supervisor:start_link(?MODULE, MFA).

init({M,F,A}) ->
    MaxRestart = 5,
    MaxTime = 3600,
    {ok, {{simple_one_for_one, MaxRestart, MaxTime},
          [{ppool_worker,
            {M,F,A},
            temporary, 5000, worker, [M]}]}}.
    
