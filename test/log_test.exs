defmodule Marketmailer.LogTest do
	use ExUnit.Case, async: false

	require Logger

	@handler :marketmailer_log_test

	setup do
		on_exit(fn -> :logger.remove_handler(@handler) end)
		:ok
	end

	@tag :tmp_dir
	test "recreates a deleted error log and keeps logging", %{tmp_dir: dir} do
		path = Path.join(dir, "errors.jsonl")

		assert :ok = Marketmailer.Log.install_file_logger(path, @handler)
		Logger.warning("repair probe one")
		Logger.flush()
		assert File.exists?(path)
		assert File.read!(path) =~ "repair probe one"

		File.rm!(path)
		refute File.exists?(path)

		assert :ok = Marketmailer.Log.install_file_logger(path, @handler)
		Logger.warning("repair probe two")
		Logger.flush()
		assert File.exists?(path)
		assert File.read!(path) =~ "repair probe two"
	end

	@tag :tmp_dir
	test "healthy log is a no-op", %{tmp_dir: dir} do
		path = Path.join(dir, "errors.jsonl")

		assert :ok = Marketmailer.Log.install_file_logger(path, @handler)
		assert :ok = Marketmailer.Log.install_file_logger(path, @handler)
		assert File.exists?(path)
	end

	test "the test environment points every log sink away from the production log" do
		path = Marketmailer.Log.error_log_path()

		assert path == "logs/test.jsonl"
		assert path != "logs/errors.jsonl"
		assert Path.dirname(path) == Path.dirname("logs/errors.jsonl")
	end

	@tag :tmp_dir
	test "resetting a log sink leaves sibling sinks alone", %{tmp_dir: dir} do
		prod = Path.join(dir, "errors.jsonl")
		prod_rotated = Path.join(dir, "errors.jsonl.1.gz")
		test_sink = Path.join(dir, "test.jsonl")
		test_rotated = Path.join(dir, "test.jsonl.1.gz")

		for file <- [prod, prod_rotated, test_sink, test_rotated], do: File.write!(file, "x")

		assert :ok = Marketmailer.Log.reset_error_log(test_sink)

		refute File.exists?(test_sink)
		refute File.exists?(test_rotated)
		assert File.exists?(prod)
		assert File.exists?(prod_rotated)
	end

	@tag :tmp_dir
	test "a boot keeps the previous generation instead of deleting it", %{tmp_dir: dir} do
		path = Path.join(dir, "errors.jsonl")
		rotated = Path.join(dir, "errors.jsonl.1.gz")
		previous = Marketmailer.Log.previous_error_log_path(path)

		File.write!(path, "boot one")
		File.write!(rotated, "x")

		assert :ok = Marketmailer.Log.reset_error_log(path)

		refute File.exists?(path)
		refute File.exists?(rotated)
		assert File.read!(previous) == "boot one"

		File.write!(path, "boot two")

		assert :ok = Marketmailer.Log.reset_error_log(path)

		assert File.read!(previous) == "boot two"
	end

	describe "the JSON formatter" do
		test "gives third-party records an event and the emitting module" do
			json =
				format(%{
					level: :warning,
					msg: {:string, "Request to \"/interactions/123/abc/callback\" was closed"},
					meta: %{time: System.system_time(:microsecond), mfa: {Nostrum.Shard, :handle, 1}}
				})

			assert json =~ ~s("event":"external_log")
			assert json =~ ~s("logger":"Nostrum.Shard")
			refute json =~ "abc/callback"
			assert json =~ "/interactions/123/<redacted>"
		end

		test "leaves structured records alone and adds no logger field" do
			json =
				format(%{
					level: :warning,
					msg: {:report, %{event: "esi_error_limit_pause", message: "ESI limit low"}},
					meta: %{time: System.system_time(:microsecond), mfa: {ESI, :note_wait, 2}}
				})

			assert json =~ ~s("event":"esi_error_limit_pause")
			refute json =~ "external_log"
			refute json =~ "logger"
		end
	end

	defp format(event) do
		event
		|> Marketmailer.Log.Format.format(pretty: false, color: false)
		|> IO.iodata_to_binary()
	end

	test "the default error log path stays the production file" do
		configured = Application.get_env(:marketmailer, :error_log_path)
		Application.delete_env(:marketmailer, :error_log_path)

		on_exit(fn ->
			if configured, do: Application.put_env(:marketmailer, :error_log_path, configured)
		end)

		assert Marketmailer.Log.error_log_path() == "logs/errors.jsonl"
	end
end
