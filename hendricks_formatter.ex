defmodule HendricksFormatter do
	@moduledoc """
	This module is a formatter plugin for Elixir's `mix format` task
	that converts leading whitespace to tabs.
	It tries to intelligently determine the tab width based on the most common
	counts of leading space runs in the file.
	It allows additional space characters for minor adjustments that are below the tab width.
	OK, why tabs? Why resurrect this age-old nerd debate again?
	Very simple: It's an accessibility issue:
	https://adamtuttle.codes/blog/2021/tabs-vs-spaces-its-an-accessibility-issue/
	https://alexandersandberg.com/articles/default-to-tabs-instead-of-spaces-for-an-accessible-first-environment/
	UNFORTUNATELY, at this time, Elixir's formatter `mix format` always assumes spaces.
	WELL, NOT ANYMORE! This plugin fixes that.
	Obligatory: https://www.youtube.com/watch?v=SsoOG6ZeyUI
	Note: To set the default tab width on your terminal (which unfortunately defaults to 8),
	run: `tabs -2` (or whatever width you want), possibly adding it to your dotfiles.
	To alter your .gitconfig to show tabs with 2 spaces if you use delta, try this:
	[core]
		pager = delta --tabs=2
	[interactive]
		difffilter = delta --tabs=2
	"""
	@behaviour Mix.Tasks.Format

	def features(_opts) do
		[extensions: [".ex", ".exs", ".erl"]]
	end

	defp gcd(a, 0), do: a
	defp gcd(0, b), do: b
	defp gcd(a, b) when a > b, do: gcd(a - b, b)
	defp gcd(a, b), do: gcd(a, b - a)

	defp determine_tab_size_in_spaces(lines) do
		linecount = length(lines)
		# do not accept a tab width that occurs less frequently than
		# 5% of the line count plus 1
		minimum_significant_frequency = trunc(linecount / 20) + 1

		lines
		|> Enum.reduce(%{}, fn line, acc ->
			case Regex.run(~r/^( *)/, line) do
				[_, spaces] ->
					spaces_count = String.length(spaces)
					Map.update(acc, spaces_count, 1, &(&1 + 1))

				_ ->
					acc
			end
		end)
		|> Map.to_list()
		|> Enum.filter(fn {k, v} -> k > 0 && v > minimum_significant_frequency end)
		|> Enum.sort_by(fn {k, v} -> {-v, k} end)
		|> take_top(4)
		|> Enum.reduce(0, fn {k, _}, acc -> gcd(k, acc) end)
		|> format_result()
	end

	defp take_top(list, n) when length(list) < n, do: list
	defp take_top(list, n), do: Enum.take(list, n)

	# we are not dealing with a tab width greater than 8 spaces
	defp format_result(gcd) do
		if(gcd > 8, do: 8, else: gcd)
	end

	defp count_characters(string, character) do
		String.graphemes(string)
		|> Enum.count(&(&1 == character))
	end

	defp process_reformat(lines, probable_spaces_per_tab) do
		pattern = ~r/^(?: {#{probable_spaces_per_tab}}|\t)*/
		# Replace leading spaces with tabs in each line
		Enum.map_join(lines, "\n", fn line ->
			case Regex.run(pattern, line) do
				nil ->
					line

				spaces_and_tabs when is_list(spaces_and_tabs) ->
					leading_whitespace = hd(spaces_and_tabs)
					num_spaces = count_characters(leading_whitespace, " ")
					extra_spacing = rem(num_spaces, probable_spaces_per_tab)
					num_tabs = count_characters(leading_whitespace, "\t")

					replacement =
						String.duplicate("\t", num_tabs) <>
							String.duplicate("\t", trunc(num_spaces / probable_spaces_per_tab)) <>
							String.duplicate(" ", extra_spacing)

					String.replace_prefix(line, leading_whitespace, replacement)
			end
		end)
	end

	def format(contents, _opts) do
		all_possible_line_endings = ~r/\r\n|\n|\r/
		lines = String.split(contents, all_possible_line_endings)
		probable_spaces_per_tab = determine_tab_size_in_spaces(lines)

		if probable_spaces_per_tab == 0 do
			contents
		else
			process_reformat(lines, probable_spaces_per_tab)
		end
	end
end
