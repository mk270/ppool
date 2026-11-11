% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

%% @doc Internal: supervisor of one pool.  Strategy `one_for_all'
%% (intensity 1 in 3000 ms) with the pool server as a permanent child;
%% the worker supervisor is added to it later, by the pool server.
%% @end
-module(ppool_sup).
-export([start_link/3, init/1]).
-behaviour(supervisor).

%% @doc Starts the supervisor of the pool `Name'.
-spec start_link(atom(), integer(), {module(), atom(), list()}) ->
          {ok, pid()} | ignore | {error, term()}.
start_link(Name, Limit, MFA) ->
    supervisor:start_link(?MODULE, {Name, Limit, MFA}).

init({Name, Limit, MFA}) ->
    MaxRestart = 1,
    MaxTime = 3000,
    {ok, {{one_for_all, MaxRestart, MaxTime},
          [{serv,
             {ppool_serv, start_link, [Name, Limit, self(), MFA]},
             permanent,
             5000, 
             worker,
             [ppool_serv]}]}}.
