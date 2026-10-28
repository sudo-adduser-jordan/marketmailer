defmodule Marketmailer.Stats do
	@cache_key {__MODULE__, :cache}
	@cache_ttl_ms 60_000

	def stats do
		now = System.monotonic_time(:millisecond)

		case cached(now) do
			{:ok, stats} -> {:ok, stats}
			:miss -> collect()
		end
	end

	def clear_cache do
		:persistent_term.erase(@cache_key)
		:ok
	end

	def runtime do
		%{
			page_workers: page_workers(),
			regions: length(Marketmailer.RegionManagerSupervisor.region_ids()),
			uptime_seconds: uptime_seconds(),
			sde_build: sde_build(),
			network: Marketmailer.Maintenance.status(),
			cache_entries: ets_size(:market_cache),
			esi_error_entries: ets_size(:esi_error_state),
			esi_rate_entries: ets_size(:esi_rate_state),
			janice_cache_entries: ets_size(:janice_chart_cache)
		}
		|> Map.merge(Contracts.runtime())
	end

	defp collect do
		{microseconds, result} = :timer.tc(fn -> Market.Database.get_database_stats() end)

		case result do
			{:ok, stats} ->
				stats =
					stats
					|> Map.merge(runtime())
					|> Map.put(:query_ms, div(microseconds, 1000))

				{:ok, cache(stats)}

			{:error, reason} ->
				{:error, reason}
		end
	end

	defp cached(now) do
		case :persistent_term.get(@cache_key, nil) do
			%{stats: stats, at: at} when is_integer(at) and now - at < @cache_ttl_ms -> {:ok, stats}
			_ -> :miss
		end
	end

	defp cache(stats) do
		:persistent_term.put(@cache_key, %{stats: stats, at: System.monotonic_time(:millisecond)})
		stats
	end

	def ets_size(table) do
		case :ets.whereis(table) do
			:undefined -> 0
			_ -> :ets.info(table, :size)
		end
	rescue
		_ -> 0
	end

	defp uptime_seconds do
		native = System.monotonic_time() - :erlang.system_info(:start_time)
		div(System.convert_time_unit(native, :native, :millisecond), 1_000)
	end

	defp page_workers do
		if Process.whereis(Marketmailer.Registry) do
			Marketmailer.Registry
			|> Registry.select([{{{:page, :"$1", :"$2"}, :_, :_}, [], [:"$2"]}])
			|> length()
		else
			0
		end
	rescue
		_ -> 0
	end

	defp sde_build do
		case File.ls(Path.join(:code.priv_dir(:marketmailer), "data/sde")) do
			{:ok, entries} -> newest_build(entries)
			_ -> nil
		end
	rescue
		_ -> nil
	end

	defp newest_build(entries) do
		entries
		|> Enum.filter(&Regex.match?(~r/^\d+$/, &1))
		|> Enum.max_by(&String.to_integer/1, fn -> nil end)
	end
end
