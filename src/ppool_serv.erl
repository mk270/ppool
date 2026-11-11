% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

%% @doc Internal: the pool server, a gen_server registered under the
%% pool's name.  It tracks how many workers are running, monitors them,
%% and holds the queue of waiting requests.  Applications should use
%% the `ppool' module instead.
%% @end
-module(ppool_serv).
-behaviour(gen_server).
-export([start/4, start_link/4, run/2, sync_queue/2, async_queue/2, stop/1]).
-export([status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

%% The friendly supervisor is started dynamically!
-define(SPEC(MFA),
        {worker_sup,
         {ppool_worker_sup, start_link, [MFA]},
          temporary,
          10000,
          supervisor,
          [ppool_worker_sup]}).

-record(state, {limit=0,
                sup,
                refs,
                queue=queue:new(),
				name}).

%% @doc Starts an unlinked pool server (not used by the library itself).
-spec start(atom(), integer(), pid(), {module(), atom(), list()}) ->
          {ok, pid()} | ignore | {error, term()}.
start(Name, Limit, Sup, MFA) when is_atom(Name), is_integer(Limit) ->
    gen_server:start({local, Name}, ?MODULE, {Limit, MFA, Sup, Name}, []).

%% @doc Starts a pool server linked to the caller, registered as `Name'.
%% `Sup' is the pool's supervisor, in which the worker supervisor is
%% started.
-spec start_link(atom(), integer(), pid(), {module(), atom(), list()}) ->
          {ok, pid()} | ignore | {error, term()}.
start_link(Name, Limit, Sup, MFA) when is_atom(Name), is_integer(Limit) ->
    gen_server:start_link({local, Name}, ?MODULE, {Limit, MFA, Sup, Name}, []).

%% @doc See `ppool:run/2'.
-spec run(atom(), list()) ->
          {ok, pid() | undefined} | noalloc | {error, term()}.
run(Name, Args) ->
    gen_server:call(Name, {run, Args}).

%% @doc See `ppool:sync_queue/2'.
-spec sync_queue(atom(), list()) ->
          {ok, pid() | undefined} | {error, term()}.
sync_queue(Name, Args) ->
    gen_server:call(Name, {sync, Args}, infinity).

%% @doc See `ppool:async_queue/2'.
%% A cast to a name nobody has registered is silently dropped, so a
%% mistyped pool name would look like success.  Rather than turn the
%% cast into a call (which would make the caller wait for the pool),
%% check that the name resolves first, and fail the way the calls
%% in this module do when there is no pool: exit with `noproc'.  The
%% check and the cast are not atomic; a pool that dies in between
%% still loses the request, as it would anyway.
-spec async_queue(atom(), list()) -> ok.
async_queue(Name, Args) ->
    case whereis(Name) of
        undefined ->
            exit({noproc, {gen_server, cast, [Name, {async, Args}]}});
        _Pid ->
            gen_server:cast(Name, {async, Args})
    end.

%% @doc Stops the pool server normally.  Its supervisor is
%% `permanent' for it, so the pool is restarted empty.
-spec stop(atom()) -> ok.
stop(Name) ->
    gen_server:call(Name, stop).

%% @doc See `ppool:status/1'.
-spec status(atom()) -> tuple().
status(Name) ->
	gen_server:call(Name, status).

%% The gen_server callbacks follow.  Requests: `{run, Args}',
%% `{sync, Args}' (calls) and `{async, Args}' (cast).  The queue holds
%% `{From, Args}' for sync requests and plain `Args' for async ones.
%% The `limit' field counts free slots; `refs' holds the monitor
%% references of running workers.
%% Gen server
init({Limit, MFA, Sup, Name}) ->
    %% We need to find the Pid of the worker supervisor from here,
    %% but alas, this would be calling the supervisor while it waits for us!
    self() ! {start_worker_supervisor, Sup, MFA},
    {ok, #state{limit=Limit, refs=gb_sets:empty(), name=Name}}.

%% A worker that fails to start must not take the pool down: the caller
%% (if any) gets {error, Reason}, and no slot is used.
run_worker(S = #state{sup=Sup}, Args, Sync) ->
	case start_worker(Sup, Args) of
		{ok, Pid} ->
			monitor_worker(S, Pid, Sync);
		{error, Reason} ->
			start_failed(S, Reason),
			case Sync of
				true ->
					{reply, {error, Reason}, S};
				false ->
					{noreply, S}
			end
	end.

%% supervisor:start_child/2 returns {ok, Pid}, {ok, Pid, Info} or
%% {error, Reason}; a started worker is tracked whatever Info says.
start_worker(Sup, Args) ->
	case supervisor:start_child(Sup, Args) of
		{ok, Pid} -> {ok, Pid};
		{ok, Pid, _Info} -> {ok, Pid};
		{error, _} = Error -> Error
	end.

start_failed(#state{name=Name}, Reason) ->
	error_logger:warning_msg("ppool ~p: could not start a worker: ~p~n",
	                         [Name, Reason]).

monitor_worker(S = #state{limit=N, refs=R}, Pid, Sync) ->
	Ref = erlang:monitor(process, Pid),
	NewLimit = N - 1,
	NewState = S#state{limit=NewLimit, refs=gb_sets:add(Ref,R)},
	case Sync of
		true ->
			{reply, {ok,Pid}, NewState};
		false ->
			{noreply, NewState}
	end.

handle_call({run, Args}, _From, S = #state{limit=N}) when N > 0 ->
	run_worker(S, Args, true);
handle_call({run, _Args}, _From, S=#state{limit=N}) when N =< 0 ->
	{reply, noalloc, S};

handle_call({sync, Args}, _From, S = #state{limit=N}) when N > 0 ->
	run_worker(S, Args, true);
handle_call({sync, Args},  From, S = #state{queue=Q}) ->
    {noreply, S#state{queue=queue:in({From, Args}, Q)}};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(status, _From, State) ->
	{reply, State, State};
handle_call(_Msg, _From, State) ->
    {noreply, State}.


handle_cast({async, Args}, S=#state{limit=N}) when N > 0 ->
	run_worker(S, Args, false);
handle_cast({async, Args}, S=#state{limit=N, queue=Q}) when N =< 0 ->
	NewLimit = N,
    {noreply, S#state{limit=NewLimit, queue=queue:in(Args,Q)}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg = {'DOWN', Ref, process, _Pid, _Reason}, S = #state{refs=Refs}) ->
    case gb_sets:is_element(Ref, Refs) of
        true -> handle_down_worker(Ref, S);
        false -> {noreply, S}
    end;
handle_info({start_worker_supervisor, Sup, MFA}, S = #state{}) ->
    {ok, Pid} = supervisor:start_child(Sup, ?SPEC(MFA)),
    link(Pid),
    {noreply, S#state{sup=Pid}};
handle_info(Msg, State) ->
    io:format("Unknown msg: ~p~n", [Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

handle_down_worker(Ref, S = #state{limit=L, sup=Sup, refs=Refs}) ->
    case queue:out(S#state.queue) of
		{{value, V}, Q} ->
			Args = case V of {_From, A} -> A; A -> A end,
			case start_worker(Sup, Args) of
				{ok, Pid} ->
					replace_worker(Ref, V, Q, Pid, S);
				{error, Reason} ->
					%% drop this item, answer its caller (a sync
					%% request is waiting for a reply), and try the next
					start_failed(S, Reason),
					case V of
						{From, _} -> gen_server:reply(From, {error, Reason});
						_ -> ok
					end,
					handle_down_worker(Ref, S#state{queue=Q})
			end;
        {empty, _} ->
            {noreply, S#state{limit=L+1, refs=gb_sets:delete(Ref,Refs)}}
    end.

replace_worker(Ref, V, Q, Pid, S = #state{refs=Refs}) ->
            NewRef = erlang:monitor(process, Pid),
            NewRefs = gb_sets:insert(NewRef, gb_sets:delete(Ref,Refs)),
			case V of
				{From, _A} -> gen_server:reply(From, {ok, Pid});
				_A -> ok
			end,
            {noreply, S#state{refs=NewRefs, queue=Q}}.
