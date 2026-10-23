defmodule Marketmailer.Utils do
	@moduledoc false

	def to_number(nil), do: nil
	def to_number(number) when is_number(number), do: number * 1.0

	def to_number(binary) when is_binary(binary) do
		case Float.parse(String.trim(binary)) do
			{number, _} -> number
			:error -> nil
		end
	end

	def to_number(_), do: nil

	# 1234567 -> 1,234,567 (Discord renders thousands separators fine).
	def group_digits(digits) do
		sign = if String.starts_with?(digits, "-"), do: "-", else: ""
		digits = String.trim_leading(digits, "-")

		digits
		|> String.reverse()
		|> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
		|> String.reverse()
		|> then(&(sign <> &1))
	end

	def count(nil), do: "0"
	def count(value) when is_integer(value), do: format_count(value)
	def count(value) when is_binary(value), do: value
	def count(_), do: "0"

	def format_count(value) when is_integer(value) do
		value
		|> Integer.to_string()
		|> group_digits()
	end

	def format_count(value) when is_float(value), do: format_count(round(value))
	def format_count(value) when is_binary(value), do: value
	def format_count(nil), do: "0"
	def format_count(_), do: "?"

	def share(nil, _total), do: "?"
	def share(_part, nil), do: "?"
	def share(_part, 0), do: "?"

	def share(part, total) when is_integer(part) and is_integer(total) do
		"#{Float.round(part / total * 100, 1)}%"
	end

	def share(_part, _total), do: "?"

	def millions_compact(abs_value),
		do: :erlang.float_to_binary(Float.round(abs_value / 1_000_000, 2), decimals: 2) <> "M"

	def format_isk(number) when is_number(number),
		do: (number * 1.0) |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)

	def format_list_margin(margin) do
		case to_number(margin) do
			nil ->
				"?"

			number ->
				sign = if number < 0, do: "-", else: "+"
				abs_value = abs(number)

				cond do
					abs_value >= 1_000_000 -> "#{sign}#{Float.round(abs_value / 1_000_000, 1)}M"
					abs_value >= 1_000 -> "#{sign}#{Float.round(abs_value / 1_000, 1)}k"
					true -> "#{sign}#{:erlang.float_to_binary(Float.round(abs_value, 2), decimals: 2)}"
				end
		end
	end

	def format_security(security) do
		case to_number(security) do
			nil -> "?"
			number -> Float.round(number, 1)
		end
	end

	def price_value(price) do
		case to_number(price) do
			nil ->
				"? ISK"

			number ->
				abs_value = abs(number)
				formatted = if abs_value >= 1_000_000, do: millions_compact(abs_value), else: format_isk(abs_value)
				prefix = if number < 0, do: "-", else: ""
				"#{prefix}#{formatted} ISK"
		end
	end

	def margin_value(nil), do: "? ISK"

	def margin_value(profit) when is_number(profit) do
		sign = if profit >= 0, do: "+", else: "-"
		abs_value = abs(profit * 1.0)

		if abs_value >= 1_000_000 do
			"#{sign}#{millions_compact(abs_value)} ISK"
		else
			"#{sign}#{format_isk(abs_value)} ISK"
		end
	end

	def or_unknown(nil), do: "?"
	def or_unknown(""), do: "?"
	def or_unknown(value), do: value

	def list_truncate(nil, _max), do: "?"
	def list_truncate("", _max), do: "?"

	def list_truncate(name, max) when is_binary(name) and is_integer(max) do
		name = String.trim(name)

		cond do
			name == "" -> "?"
			String.length(name) <= max -> name
			true -> String.slice(name, 0, max - 1) <> "…"
		end
	end

	def list_truncate(_, _), do: "?"

	def format_bytes(nil, _page_size), do: "?"
	def format_bytes(_page_count, nil), do: "?"

	def format_bytes(page_count, page_size) when is_integer(page_count) and is_integer(page_size) do
		bytes = page_count * page_size

		cond do
			bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
			bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
			bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
			true -> "#{bytes} B"
		end
	end

	def format_bytes(_page_count, _page_size), do: "?"

	def format_milliseconds(nil), do: "?"
	def format_milliseconds(ms) when is_integer(ms), do: "#{format_count(ms)} ms"
	def format_milliseconds(_), do: "?"

	def format_uptime(nil), do: "?"

	def format_uptime(seconds) when is_integer(seconds) and seconds >= 0 do
		days = div(seconds, 86_400)
		hours = div(rem(seconds, 86_400), 3_600)
		minutes = div(rem(seconds, 3_600), 60)

		cond do
			days > 0 -> "#{days}d #{hours}h"
			hours > 0 -> "#{hours}h #{minutes}m"
			true -> "#{minutes}m"
		end
	end

	def format_uptime(_), do: "?"

	def format_ttl(ttl_ms) do
		total_seconds = div(ttl_ms, 1_000)
		minutes = div(total_seconds, 60)
		seconds = rem(total_seconds, 60)

		min = String.pad_leading("#{minutes}", 2, "0")
		sec = String.pad_leading("#{seconds}", 2, "0")

		"#{min}:#{sec}"
	end

	def format_footer_date(ts) when is_binary(ts) do
		case DateTime.from_iso8601(String.trim(ts)) do
			{:ok, dt, _} -> Calendar.strftime(dt, "%b %d, %Y %H:%M UTC")
			_ -> Calendar.strftime(DateTime.utc_now(), "%b %d, %Y %H:%M UTC")
		end
	end

	# SQLite stores NaiveDateTime UTC seconds; a missing/failed parse must not
	# fall back to "now" the way the footer's DateTime helper does.
	def format_timestamp(nil), do: "?"
	def format_timestamp(""), do: "?"

	def format_timestamp(timestamp) when is_binary(timestamp) do
		case NaiveDateTime.from_iso8601(String.trim(timestamp)) do
			{:ok, at} -> Calendar.strftime(at, "%b %d, %Y %H:%M UTC")
			{:error, _} -> "?"
		end
	end

	def format_timestamp(_), do: "?"

	# The market table stores NaiveDateTime UTC seconds ("2026-10-17T01:34:03").
	def relative_age(nil), do: "never"
	def relative_age(""), do: "never"

	def relative_age(timestamp) when is_binary(timestamp) do
		case NaiveDateTime.from_iso8601(String.trim(timestamp)) do
			{:ok, at} -> relative_age_seconds(NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :second))
			{:error, _} -> "?"
		end
	end

	def relative_age(%NaiveDateTime{} = at),
		do: relative_age_seconds(NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :second))

	def relative_age(_), do: "?"

	defp relative_age_seconds(seconds) do
		cond do
			seconds < 60 -> "#{max(seconds, 0)}s ago"
			seconds < 3_600 -> "#{div(seconds, 60)}m ago"
			seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
			true -> "#{div(seconds, 86_400)}d ago"
		end
	end

	def format_failure(%{page: nil, reason: reason}), do: "failed: #{reason}"
	def format_failure(%{page: page, reason: reason}), do: "page #{page}: #{reason}"
	def format_failure(reason), do: "failed: #{inspect(reason)}"
end
