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

start_link() ->
    Return = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
    io:format("start_link: ~p~n", [Return]),
    Return.

init([]) ->
    %% Print once immediately (optional)
    io:format("tick (init)~n", []),

    %% Schedule first tick in 600 ms
    erlang:send_after(600, self(), tick),

    % %% Connect to Postgres (adjust these values)
    % {ok, DatabaseConnection} = epgsql:connect(#{
    %     host => "localhost",
    %     port => 5432,
    %     database => "postgres",
    %     username => "postgres",
    %     password => "postgres"
    % }),

    % State = #state{database_connection = DatabaseConnection},
    % io:format("Connected to Postgres: ~p~n", [DatabaseConnection]),
    % {ok, State}.

    State = [],
    Return = {ok, State},
    io:format("init: ~p~n", [State]),
    Return.

handle_call(_Request, _From, State) ->
    Reply = ok,
    Return = {reply, Reply, State},
    io:format("handle_call: ~p~n", [Return]),
    Return.

handle_cast(_Msg, State) ->
    Return = {noreply, State},
    io:format("handle_cast: ~p~n", [Return]),
    Return.

handle_info(_Info, State) ->

    %% Print every 0.6 seconds
    io:format("tick~n", []),

    %% Schedule the next tick
    erlang:send_after(600, self(), tick),

    Return = {noreply, State},
    io:format("handle_info: ~p~n", [Return]),
    Return.

terminate(_Reason, _State) ->
    % epgsql:close(Conn),
    % io:format("Postgres connection closed~n", []),


    Return = ok,
    io:format("terminate: ~p~n", [Return]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    Return = {ok, State},
    io:format("code_change: ~p~n", [Return]),
    Return.

