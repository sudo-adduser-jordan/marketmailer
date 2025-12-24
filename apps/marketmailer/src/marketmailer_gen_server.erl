-module(marketmailer_gen_server).
-behaviour(gen_server).
-export([
    start_link/0
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {database_connection}).

start_link() ->
    Return = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
    io:format("start_link \t| ~p~n", [Return]),
    Return.

init([]) ->
    erlang:send_after(1200, self(), tick),

    {ok, DatabaseConnection} = database:connect(),
    State = #state{database_connection = DatabaseConnection},

    % State = [],
    Return = {ok, State},
    io:format("init State \t| ~p~n", [State]),
    Return.

handle_call(_Request, _From, State) ->
    Reply = ok,
    Return = {reply, Reply, State},
    io:format("handle_call \t| ~p~n", [Return]),
    Return.

handle_cast(_Msg, State) ->
    Return = {noreply, State},
    io:format("handle_cast \t| ~p~n", [Return]),
    Return.

handle_info(_Info, State) ->
    erlang:send_after(600, self(), tick),

    Return = {noreply, State},
    io:format("handle_info \t| ~p~n", [Return]),
    Return.

terminate(_Reason, #state{database_connection = DatabaseConnection}) ->
    epgsql:close(DatabaseConnection),
    io:format("Postgres connection closed~n", []),
    Return = ok,
    io:format("terminate \t| ~p~n", [Return]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    Return = {ok, State},
    io:format("code_change \t| ~p~n", [Return]),
    Return.

