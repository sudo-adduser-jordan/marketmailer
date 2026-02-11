# Marketmailer

**TODO: Add description**

```sh
sudo docker exec -it pgadmin  /bin/bash 
clear; source .env; mix start
sudo docker cp postgres-latest.dmp pgadmin:/postgres-latest.dmp
sudo docker cp postgres-latest.dmp pgadmin:/var/lib/pgadmin/storage/postgres_postgres.com

https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip
```


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `marketmailer` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:marketmailer, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/marketmailer>.

