{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
ExUnit.start()
