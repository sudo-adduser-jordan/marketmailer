defmodule Marketmailer.Stats do
	@moduledoc false

	# Database + market cache statistics for the /database_stats slash command.
	#
	# The aggregate is a full scan of the market table (~1s on a multi-million
	# row file). :timer.tc/1 runs it in the caller, so it only stays off the
	# gateway consumer when the caller is the deferred Task (run_stats_task);
	# the two fallback paths — the defer failed, or no bot is registered — run it
	# inline on the consumer and block it for that ~1s. The result is reused for
	# @cache_ttl_ms. The cache lives in :persistent_term on purpose: a new
	# supervised process or a new ETS table would not exist after a hot
	# upgrade (the supervisor keeps its old child list and Application.start/2
	# does not re-run), while a persistent_term key survives the upgrade with
	# no process to supervise.

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
			cache_entries: ets_size(:market_cache),
			esi_error_entries: ets_size(:esi_error_state),
			janice_cache_entries: ets_size(:janice_chart_cache)
		}
	end

	defp collect do
		{microseconds, result} = :timer.tc(fn -> Market.Database.get_database_stats() end)

		case result do
			{:ok, stats} ->
				# A failed lookup is never cached: the next command retries.
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

	# Public so the missing-table guard is directly testable; every other
	# caller goes through runtime/0.
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

	# One page worker per (region, page) registered as {:page, region, page}.
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

	# The SDE import task writes priv/data/sde/<build>/ relative to the project
	# root; resolve it off :code.priv_dir so the release finds its own copy (and
	# falls back to nil when priv/data is not shipped).
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
