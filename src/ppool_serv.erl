% Copyright (c) 2009 Frederic Trottier-Hebert; see LICENSE.txt for terms

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

start(Name, Limit, Sup, MFA) when is_atom(Name), is_integer(Limit) ->
    gen_server:start({local, Name}, ?MODULE, {Limit, MFA, Sup, Name}, []).

start_link(Name, Limit, Sup, MFA) when is_atom(Name), is_integer(Limit) ->
    gen_server:start_link({local, Name}, ?MODULE, {Limit, MFA, Sup, Name}, []).

run(Name, Args) ->
    gen_server:call(Name, {run, Args}).

sync_queue(Name, Args) ->
    gen_server:call(Name, {sync, Args}, infinity).

async_queue(Name, Args) ->
    gen_server:cast(Name, {async, Args}).

stop(Name) ->
    gen_server:call(Name, stop).

status(Name) ->
	gen_server:call(Name, status).

%% Gen server
init({Limit, MFA, Sup, Name}) ->
    %% We need to find the Pid of the worker supervisor from here,
    %% but alas, this would be calling the supervisor while it waits for us!
    self() ! {start_worker_supervisor, Sup, MFA},
    {ok, #state{limit=Limit, refs=gb_sets:empty(), name=Name}}.

run_worker(S = #state{limit=N, sup=Sup, refs=R}, Args, Sync) ->
    lager:info("ppool_serv: starting worker: ~p", [Args]),
    lager:info("sup: ~p", [Sup]),
	{ok, Pid} = supervisor:start_child(Sup, Args),
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
			{ok, Pid} = supervisor:start_child(Sup, Args),
            NewRef = erlang:monitor(process, Pid),
            NewRefs = gb_sets:insert(NewRef, gb_sets:delete(Ref,Refs)),
			case V of
				{From, _A} -> gen_server:reply(From, {ok, Pid});
				_A -> ok
			end,
            {noreply, S#state{refs=NewRefs, queue=Q}};
        {empty, _} ->
            {noreply, S#state{limit=L+1, refs=gb_sets:delete(Ref,Refs)}}
    end.
