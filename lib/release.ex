defmodule Marketmailer.Release do
	def prune_local_data(release) do
		vsn = release.applications |> Map.get(:marketmailer, []) |> Keyword.get(:vsn, release.version)
		priv = Path.join([release.path, "lib", "marketmailer-#{vsn}", "priv", "data"])

		for entry <- entries(priv), entry != ".gitkeep", do: File.rm_rf!(Path.join(priv, entry))

		release
	end

	defp entries(path) do
		case File.ls(path) do
			{:ok, entries} -> entries
			{:error, _} -> []
		end
	end
end
