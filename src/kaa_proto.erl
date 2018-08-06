-module(kaa_proto).

-export([worker/1,
    exec/1
]).

-include("kaa_core.hrl").
-include("kaa.hrl"). % auto-generated by gpb
-include("kaa_worker.hrl"). % auto-generated by gpb
-include("kaa_error.hrl"). % auto-generated by gpb
-include("kaa_result.hrl"). % auto-generated by gpb

worker(Pid) when not is_pid(Pid) ->
    KaaError = #'KaaError'{error = "no_jun_worker"},
    kaa_error:encode_msg(KaaError);
worker(Pid) when is_pid(Pid)     ->
    KaaWorker = #'KaaWorker'{jun_worker = pid_to_list(Pid)},
    kaa_worker:encode_msg(KaaWorker).

exec(PBMsg) when not is_binary(PBMsg) ->
    lager:error("invalid kaa protobuf message ~p", [invalid_binary]),
    KaaError = #'KaaError'{error = "invalid_kaa_proto_message"},
    kaa_error:encode_msg(KaaError);
exec(PBMsg) when is_binary(PBMsg)     ->
    case catch kaa:decode_msg(PBMsg, 'Kaa') of
        {'EXIT', Error}  ->
            lager:error("invalid kaa protobuf message ~p", [Error]),
            KaaError = #'KaaError'{error = "invalid_kaa_proto_message"},
            kaa_error:encode_msg(KaaError);
        #'Kaa'{} = KaaPB ->
            % decompose message and execute through jun!
            JunWorker = list_to_pid(KaaPB#'Kaa'.jun_worker),
            Mod = KaaPB#'Kaa'.module,
            Fn = KaaPB#'Kaa'.'function',
            Result = exec_jun(KaaPB#'Kaa'.arguments, JunWorker, Mod, Fn),
            encode_result(Result)
    end.

%% @hidden

exec_jun({core, #m_core{argument = Argument, keywords = Keywords}},
        JunWorker, Mod, Fn) ->
    Pid = pid_to_list(self()),
    % parse keywords in order to convert to a plist for jun
    Keywords0 = parse_keywords(Keywords),
    % maybe argument use a series, check for it in kaa environment
    Argument0 = parse_argument(Argument, Pid),
    Mod:Fn(JunWorker, Argument0, Keywords0);
exec_jun({frame, #m_frame{dataframe = MemId, axis = Axis, keywords = Keywords}},
        JunWorker, Mod, Fn) ->
    Pid = pid_to_list(self()),
    % lookup for a dataframe if is in mem, otherwise use original
    [{_, DataFrame}] = case ets:lookup(?KAA_ENVIRONMENT(Pid), MemId) of
      []    -> [{exclude, MemId}];
      Found -> Found
    end,
    % parse keywords in order to convert to a plist for jun
    Keywords0 = parse_keywords(Keywords),
    % maybe dont use axis, this must be optional in proto
    case Axis of
        undefined ->
            Mod:Fn(JunWorker, DataFrame, Keywords0);
        _         ->
            % this rare condition happens when jun tries to use a integer value as
            % argument of a function, for example, head or tail.
            % a function could receive a float value?, if so, then parse.
            Axis0 = parse_argument(Axis, Pid),
            Mod:Fn(JunWorker, DataFrame, Axis0, Keywords0)
    end.

%% @hidden

encode_result({ok, {?SERIES, {'$erlport.opaque', python, _} = Series}})       ->
    MemId = random_key(),
    Pid = pid_to_list(self()),
    true = ets:insert(?KAA_ENVIRONMENT(Pid), {binary_to_list(MemId), Series}),
    KaaResult = #'KaaResult'{ok = "ok", result = {series, MemId}},
    kaa_result:encode_msg(KaaResult);
encode_result({ok, {?DATAFRAME, {'$erlport.opaque', python, _} = DataFrame}}) ->
    MemId = random_key(),
    Pid = pid_to_list(self()),
    true = ets:insert(?KAA_ENVIRONMENT(Pid), {binary_to_list(MemId), DataFrame}),
    KaaResult = #'KaaResult'{ok = "ok", result = {dataframe, MemId}},
    kaa_result:encode_msg(KaaResult);
encode_result({ok, {?GROUPBY, {'$erlport.opaque', python, _} = GroupBy}}) ->
    MemId = random_key(),
    Pid = pid_to_list(self()),
    true = ets:insert(?KAA_ENVIRONMENT(Pid), {binary_to_list(MemId), GroupBy}),
    KaaResult = #'KaaResult'{ok = "ok", result = {groupby, MemId}},
    kaa_result:encode_msg(KaaResult);
% the process of return plotting through pb is complex, since is an opaque term
% similar to dataframe, so maybe store in an internal storage to execute tasks
% in the plot after creation.
encode_result({ok, {?AXESPLOT, {'$erlport.opaque', python, _} = Plot}}) ->
    PlotBin = term_to_binary(Plot),
    KaaResult = #'KaaResult'{ok = "ok", result = {axesplot, binary_to_list(PlotBin)}},
    kaa_result:encode_msg(KaaResult);
encode_result({ok, {?SEABORNPLOT, {'$erlport.opaque', python, _} = Plot}}) ->
    PlotBin = term_to_binary(Plot),
    KaaResult = #'KaaResult'{ok = "ok", result = {seabornplot, binary_to_list(PlotBin)}},
    kaa_result:encode_msg(KaaResult);
encode_result({ok, {?PLOTLY, A}})                               ->
    PlotPickled = atom_to_list(A),
    KaaResult = #'KaaResult'{ok = "ok", result = {iplot, PlotPickled}},
    kaa_result:encode_msg(KaaResult);
encode_result({ok, I}) when is_integer(I)                       ->
    KaaResult = #'KaaResult'{ok = "ok", result = {inumber, I}},
    kaa_result:encode_msg(KaaResult);
encode_result({ok, F}) when is_float(F)                         ->
    KaaResult = #'KaaResult'{ok = "ok", result = {dnumber, F}},
    kaa_result:encode_msg(KaaResult);
encode_result({ok, B}) when is_binary(B)                        ->
    KaaResult = #'KaaResult'{ok = "ok", result = {string, binary_to_list(B)}},
    kaa_result:encode_msg(KaaResult);
encode_result({ok, S}) when is_list(S)                          ->
    KaaResult = #'KaaResult'{ok = "ok", result = {string, S}},
    kaa_result:encode_msg(KaaResult);
encode_result({error, {Error, Description}})                    ->
    KaaError = #'KaaError'{error = atom_to_list(Error),
        description = Description},
    kaa_error:encode_msg(KaaError).

%% @hidden

random_key() ->
    Seq = lists:seq(1, 100),
    Chars = "abcdeefghijklmnopqrstuvwxyz",
    R = lists:foldl(fun(_, Acc) ->
        L = length(Chars),
        [ lists:nth(rand:uniform(L), Chars) | Acc]
    end, [], Seq),
    list_to_binary(R).

%% @hidden

parse_keywords(Keywords) ->
    lists:map(fun(#'Keywords'{key = Key, value = Value}) ->
        case catch list_to_integer(Value) of
            {'EXIT', _} -> {list_to_atom(Key), list_to_atom(Value)};
            ValueInt    -> {list_to_atom(Key), ValueInt}
        end
    end, Keywords).

%% @hidden

parse_argument(Argument, Pid) ->
    case catch list_to_integer(Argument) of
        {'EXIT', _} ->
            % if the argument is a series then check if we hold into kaa environment
            case ets:lookup(?KAA_ENVIRONMENT(Pid), Argument) of
                [{_, Series}] -> Series;
                _             -> list_to_atom(Argument)
            end;
        ArgumentInt -> ArgumentInt
    end.
