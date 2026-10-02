defmodule Marketmailer.LogRepairTest do
	# The file logger holds its fd open: deleting logs/errors.jsonl while
	# running orphans the descriptor. ensure_file_logger/0 must recreate it.
	# Custom path/handler args keep this off the live log file.
	use ExUnit.Case, async: false

	require Logger

	@handler :marketmailer_log_repair_test

	setup do
		on_exit(fn -> :logger.remove_handler(@handler) end)
		:ok
	end

	@tag :tmp_dir
	test "recreates a deleted error log and keeps logging", %{tmp_dir: dir} do
		path = Path.join(dir, "errors.jsonl")

		assert :ok = Marketmailer.Application.ensure_file_logger(path, @handler)
		Logger.warning("repair probe one")
		Logger.flush()
		assert File.exists?(path)
		assert File.read!(path) =~ "repair probe one"

		File.rm!(path)
		refute File.exists?(path)

		assert :ok = Marketmailer.Application.ensure_file_logger(path, @handler)
		Logger.warning("repair probe two")
		Logger.flush()
		assert File.exists?(path)
		assert File.read!(path) =~ "repair probe two"
	end

	@tag :tmp_dir
	test "healthy log is a no-op", %{tmp_dir: dir} do
		path = Path.join(dir, "errors.jsonl")

		assert :ok = Marketmailer.Application.ensure_file_logger(path, @handler)
		assert :ok = Marketmailer.Application.ensure_file_logger(path, @handler)
		assert File.exists?(path)
	end
end
