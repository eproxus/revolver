-module (revolver).

-behaviour (gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([balance/2, balance/3, map/2, start_link/3, pid/1, connect/1]).

-define(DEFAULTMINALIVERATIO,  1.0).
-define(DEFAULRECONNECTDELAY,  1000). % ms
-define(DEFAULTCONNECTATSTART, true).
-define(DEFAULTMAXMESSAGEQUEUELENGTH, undefined).

-record(state, {
    connected                :: boolean(),
    supervisor               :: supervisor:sup_ref(),
    pid_table                :: ets:tab(),
    last_pid                 :: undefined | pid(),
    pids_count_original      :: undefined | integer(),
    min_alive_ratio          :: float(),
    reconnect_delay          :: integer(),
    max_message_queue_length :: undefined | integer()
}).

start_link(Supervisor, ServerName, Options) when is_map(Options) ->
    gen_server:start_link({local, ServerName}, ?MODULE, {Supervisor, Options}, []).

balance(Supervisor, BalancerName) ->
    revolver_sup:start_link(Supervisor, BalancerName, #{}).

balance(Supervisor, BalancerName, Options) ->
    revolver_sup:start_link(Supervisor, BalancerName, Options).

pid(PoolName) ->
    gen_server:call(PoolName, pid).

map(ServerName, Fun) ->
    gen_server:call(ServerName, {map, Fun}).

connect(PoolName) ->
    gen_server:call(PoolName, connect).

init({Supervisor, Options}) ->
    MinAliveRatio         = maps:get(min_alive_ratio,  Options, ?DEFAULTMINALIVERATIO),
    ReconnectDelay        = maps:get(reconnect_delay,  Options, ?DEFAULRECONNECTDELAY),
    ConnectAtStart        = maps:get(connect_at_start, Options, ?DEFAULTCONNECTATSTART),
    MaxMessageQueueLength = maps:get(max_message_queue_length, Options, ?DEFAULTMAXMESSAGEQUEUELENGTH),

    PidTable = ets:new(pid_table, [private, duplicate_bag]),

    State = #state{
        connected                = false,
        supervisor               = Supervisor,
        pids_count_original      = undefined,
        min_alive_ratio          = MinAliveRatio,
        pid_table                = PidTable,
        last_pid                 = undefined,
        reconnect_delay          = ReconnectDelay,
        max_message_queue_length = MaxMessageQueueLength
    },
    maybe_connect(ConnectAtStart),
    {ok, State}.

maybe_connect(true) ->
  self() ! connect;
maybe_connect(_) ->
  noop.

% revolver is disconnected
handle_call(pid, _From, State = #state{connected = false}) ->
    {reply, {error, disconnected}, State};
% no limit on the message queue is defined
handle_call(pid, _From, State = #state{last_pid = LastPid, pid_table = PidTable, max_message_queue_length = undefined}) ->
    Pid = next_pid(PidTable, LastPid),
    {reply, Pid, State#state{last_pid = Pid}};
% message queue length is limited
handle_call(pid, _From, State = #state{last_pid = LastPid, pid_table = PidTable, max_message_queue_length = MaxMessageQueueLength}) ->
    {Pid, NextLastPid} = first_available(PidTable, LastPid, MaxMessageQueueLength),
    {reply, Pid, State#state{last_pid = NextLastPid}};

handle_call({map, Fun}, _From, State = #state{pid_table = PidTable}) ->
    % we are reconnecting here to make sure we
    % have an up to date version of the pids
    StateNew = connect_internal(State),
    Pids     = ets:foldl(fun({Pid, _}, Acc) -> [Pid|Acc] end, [], PidTable),
    Reply    = lists:map(Fun, Pids),
    {reply, Reply, StateNew};

handle_call(connect, _From, State) ->
    NewSate = connect_internal(State),
    Reply =
    case NewSate#state.connected of
        true ->
            ok;
        false ->
            {error, not_connected}
    end,
    {reply, Reply, NewSate}.

-dialyzer({no_return, [handle_cast/2]}).
handle_cast(_, State) ->
    throw("not implemented"),
    {noreply, State}.

handle_info(connect, State) ->
    {noreply, connect_internal(State)};

handle_info({'DOWN', _, _, Pid, _}, State = #state{supervisor = Supervisor, pid_table = PidTable, pids_count_original = PidsCountOriginal, min_alive_ratio = MinAliveRatio}) ->
    error_logger:info_msg("~p: The process ~p (child of ~p) died.\n", [?MODULE, Pid, Supervisor]),
    ets:delete(PidTable, Pid),
    StateNew =
    case too_few_pids(PidTable, PidsCountOriginal, MinAliveRatio) of
        true ->
            error_logger:warning_msg("~p: Reloading children from supervisor ~p.\n", [?MODULE, Supervisor]),
            connect_internal(State);
        false ->
            State
    end,
    {noreply, StateNew}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

next_pid(PidTable, LastPid) ->
    case ets:next(PidTable, LastPid) of
        '$end_of_table' ->
            ets:first(PidTable);
        Value ->
            Value
    end.

first_available(PidTable, LastPid, MaxMessageQueueLength) ->
    first_available(PidTable, next_pid(PidTable, LastPid), LastPid, MaxMessageQueueLength).
% we arrived at the first pid (or we have only one in total)
% so we check one last time before we return overload
first_available(_, StartingPid, StartingPid, MaxMessageQueueLength) ->
    case overloaded(StartingPid, MaxMessageQueueLength) of
        false ->
            {StartingPid, StartingPid};
        true  ->
            {{error, overload}, StartingPid}
    end;
% new pid candidate: check message queue
% and maybe recurse
first_available(PidTable, NextPid, StartingPid, MaxMessageQueueLength) ->
    case overloaded(NextPid, MaxMessageQueueLength) of
        false ->
            {NextPid, NextPid};
        true  ->
            first_available(PidTable, next_pid(PidTable, NextPid), StartingPid, MaxMessageQueueLength)
    end.

overloaded(Pid, MaxMessageQueueLength) ->
    revolver_utils:message_queue_len(Pid) > MaxMessageQueueLength.

too_few_pids(PidTable, PidsCountOriginal, MinAliveRatio) ->
    table_size(PidTable) / PidsCountOriginal < MinAliveRatio.

connect_internal(State = #state{ supervisor = Supervisor, pid_table = PidTable, reconnect_delay = ReconnectDelay }) ->
    case revolver_utils:child_pids(Supervisor) of
        {error, supervisor_not_running} ->
            ets:delete_all_objects(PidTable),
            schedule_reconnect(ReconnectDelay),
            State#state{ connected = false };
        Pids ->
            PidsNew      = lists:filter(fun(E) -> ets:lookup(PidTable, E) =:= [] end, Pids),
            PidsWithRefs = [{Pid, revolver_utils:monitor(Pid)}|| Pid <- PidsNew],
            true         = ets:insert(PidTable, PidsWithRefs),
            StateNew     = State#state{ last_pid =  ets:first(PidTable), pids_count_original = table_size(PidTable) },
            case table_size(PidTable) of
                0 ->
                    error_logger:error_msg(
                        "~p zero PIDs for ~p, disconnected.\n",
                        [?MODULE, Supervisor]),
                    schedule_reconnect(ReconnectDelay),
                    StateNew#state{ connected = false };
                _ ->
                    StateNew#state{ connected = true }
            end
    end.

schedule_reconnect(Delay) ->
    error_logger:error_msg("~p trying to reconnect in ~p ms.\n", [?MODULE, Delay]),
    erlang:send_after(Delay, self(), connect).


table_size(Table) ->
        {size, Count} = proplists:lookup(size, ets:info(Table)),
        Count.
