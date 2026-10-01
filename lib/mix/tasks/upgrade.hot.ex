defmodule Mix.Tasks.Upgrade.Hot do
	@shortdoc "Compile and hot-load beams into the live node (no restart)"

	@moduledoc """
	Hot-reloads the running poller without a restart: compiles locally, then
	rpc-loads the app's beams into the live node (first arg or
	`MARKETMAILER_NODE`, default `marketmailer@<hostname>`).

	The live node must be distributed with a matching cookie
	(`MARKETMAILER_COOKIE` env or `~/.config/marketmailer/cookie`; see
	`task live:start` and `deploy/marketmailer.service`).

	Processes keep their current state: safe for logic-only changes. State
	shape changes (GenServer state, ETS tuple shapes) need a poller restart.
	"""

	use Mix.Task

	@impl true
	def run(args) do
		Mix.Task.run("compile", ["--warnings-as-errors"])
		target = target_node(args)
		ensure_distribution!()
		set_cookie!(target)

		if !Node.connect(target) do
			Mix.raise("upgrade.hot: cannot connect to #{target}; is the live node running? (`task live:start`)")
		end

		ebin = Path.join(to_string(:code.lib_dir(:marketmailer)), "ebin")
		beams = Path.wildcard(Path.join(ebin, "*.beam"))

		mods = select_modules(beams, args)

		if mods == [] do
			Mix.raise("upgrade.hot: no matching beams for #{inspect(args)}")
		end

		results =
			Enum.map(mods, fn {mod, file} ->
				{:ok, bin} = File.read(file)
				:rpc.call(target, :code, :soft_purge, [mod])
				{mod, :rpc.call(target, :code, :load_binary, [mod, String.to_charlist(file), bin])}
			end)

		{ok, failed} = Enum.split_with(results, fn {_mod, res} -> match?({:module, _}, res) end)

		Mix.shell().info("upgrade.hot: loaded #{length(ok)}/#{length(results)} modules into #{target}")

		if failed != [] do
			for {mod, reason} <- failed, do: Mix.shell().error("upgrade.hot: #{inspect(mod)}: #{inspect(reason)}")
			Mix.raise("upgrade.hot: #{length(failed)} modules failed to load")
		end

		:ok
	end

	defp target_node([first | _]) when is_binary(first) do
		if String.contains?(first, "@"), do: String.to_atom(first), else: default_node()
	end

	defp target_node(_), do: default_node()

	defp default_node do
		if env = System.get_env("MARKETMAILER_NODE"),
			do: String.to_atom(env),
			else: :"marketmailer@#{hostname()}"
	end

	defp hostname do
		{:ok, name} = :inet.gethostname()
		to_string(name)
	end

	defp select_modules(beams, args) do
		wanted =
			args
			|> Enum.reject(&String.contains?(&1, "@"))
			|> MapSet.new(&normalize_module/1)

		for file <- beams,
				mod = file |> Path.basename(".beam") |> String.to_atom(),
				wanted == MapSet.new() or MapSet.member?(wanted, mod),
				do: {mod, file}
	end

	# `String.to_atom("ESI")` is `:ESI`, but the beam holds `Elixir.ESI`.
	defp normalize_module("Elixir." <> _ = name), do: String.to_atom(name)
	defp normalize_module(name), do: String.to_atom("Elixir." <> name)

	defp ensure_distribution! do
		if !Node.alive?() do
			name = :"hotloader_#{System.unique_integer([:positive])}"
			{:ok, _} = :net_kernel.start([name, :shortnames])
		end

		:ok
	end

	defp set_cookie!(target) do
		cookie =
			System.get_env("MARKETMAILER_COOKIE") ||
				read_cookie_file() ||
				Mix.raise("upgrade.hot: no cookie; set MARKETMAILER_COOKIE or run `task live:cookie`")

		cookie = String.to_atom(String.trim(cookie))
		:erlang.set_cookie(Node.self(), cookie)
		Node.set_cookie(target, cookie)
	end

	defp read_cookie_file do
		path = Path.join([System.user_home!(), ".config", "marketmailer", "cookie"])

		case File.read(path) do
			{:ok, contents} -> contents
			_ -> nil
		end
	end
end
