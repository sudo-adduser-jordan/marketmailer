-module(database).

-export([
    connect/0,
    create_table/1,
    print_rows/1,
    select_all/1,
    close_connection/1
]).

-define(CREATE_TABLE_MARKET_ORDERS, "
    CREATE TABLE IF NOT EXISTS market_orders (
        id          SERIAL PRIMARY KEY,
        item        TEXT NOT NULL,
        sell_price  TEXT NOT NULL,
        buy_price   TEXT NOT NULL,
        expires     TIMESTAMP DEFAULT NOW(),
        created     TIMESTAMP DEFAULT NOW()
    )
").

-define(SELECT_ALL_EMAILS, "SELECT * FROM emails;").

connect() ->
    Host = os:getenv("POSTGRES_HOST"),
    PortStr = os:getenv("POSTGRES_PORT"),
    Database = os:getenv("POSTGRES_DATABASE"),
    User = os:getenv("POSTGRES_USER"),
    Password = os:getenv("POSTGRES_PASSWORD"),

    {ok, DatabaseConnection} = epgsql:connect(#{ 
        host => Host,
        port => erlang:list_to_integer(PortStr),
        database => Database,
        username => User,
        password => Password
    }),

    io:format("Connected to Postgres \t| ~p~n", [DatabaseConnection]),
    {ok, DatabaseConnection}.

create_table(DatabaseConnection) ->
    {ok, _Result} = epgsql:squery(DatabaseConnection, ?CREATE_TABLE_MARKET_ORDERS), 
    io:format("Created table \t| market_orders ~n", []).

print_rows(Rows) ->
    lists:foreach(fun(Row) ->
        io:format("Row \t| ~p~n", [Row])
    end, Rows).

select_all(DatabaseConnection) ->
    case epgsql:squery(DatabaseConnection, ?SELECT_ALL_EMAILS) of
        {ok, _Columns, Rows} ->
            io:format("Rows \t| ~p~n", [Rows]),
            print_rows(Rows);
        {error, Reason} ->
            io:format("Query failed \t| ~p~n", [Reason])
    end.

close_connection(DatabaseConnection) ->
    epgsql:close(DatabaseConnection),
    io:format("Postgres connection closed~n", []).