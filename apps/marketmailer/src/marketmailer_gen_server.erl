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

% -export([
%     query/1, 
%     squery/1
% ]).

%% Init with Postgres connection
-record(state, {database_connection}).


start_link() ->
    Return = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
    io:format("start_link \t| ~p~n", [Return]),
    Return.

init([]) ->

    %% Schedule first tick in 600 ms
    erlang:send_after(1200, self(), tick),
    io:format("Timer initialized \t| 1.2s~n", []),

    % %% Connect to Postgres
    {ok, DatabaseConnection} = epgsql:connect(#{
        host => "localhost",
        port => 5432,
        database => "postgres",
        username => "postgres",
        password => "postgres"
    }),

    State = #state{database_connection = DatabaseConnection},
    io:format("Connected to Postgres \t| ~p~n", [DatabaseConnection]),
    % {ok, State}.

    {ok, [], []} = epgsql:squery(DatabaseConnection, "
        CREATE TABLE IF NOT EXISTS emails (
            id SERIAL PRIMARY KEY,
            recipient TEXT NOT NULL,
            subject TEXT NOT NULL,
            body TEXT,
            sent_at TIMESTAMP DEFAULT NOW(),
            created_at TIMESTAMP DEFAULT NOW()
        )
    "),
    io:format("Created table \t| emails~n", []),
    
    % Execute a simple query
    case epgsql:squery(DatabaseConnection, "SELECT * FROM emails;") of
        {ok, _Columns, Rows} ->
            io:format("Rows \t| ~p~n", [Rows]),
            
            % Process the results
            lists:foreach(fun(Row) ->
                io:format("email \t| ~p~n", [Row])
            end, Rows);
        
        {error, Reason} ->
            io:format("Query failed \t| ~p~n", [Reason])
    end,

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

