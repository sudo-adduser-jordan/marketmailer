defmodule Market.DbWriter do
	# Single serialized writer for SQLite's single write lock.
	#
	# Hundreds of PageWorkers share a connection pool, but every pooled
	# connection still contends on the one database write lock: concurrent
	# upserts wait out busy_timeout and die with "Database busy". Funneling
	# every write through this process means the lock is never contended —
	# writes queue in the mailbox instead of failing. Reads keep flowing
	# through the Database pool via WAL.
	#
	# Falls back to direct execution (with the same busy retry) when the
	# writer is absent — e.g. a hot upgrade that does not start new
	# supervision children yet — so callers never crash on :noproc.
	use GenServer

	@call_timeout 30_000
	# Wait between contention retries inside one write (~7s total budget).
	@retry_delays [10, 25, 50, 100, 200, 400, 800, 1_600, 3_200]

	def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

	# Runs fun against the repo with no concurrent writers. Returns fun's
	# value; re-raises the last error when the retry budget is spent so
	# callers keep their existing rescue contracts.
	def write(fun) when is_function(fun, 0) do
		case GenServer.whereis(__MODULE__) do
			nil -> run(fun, @retry_delays)
			_pid -> call(fun)
		end
	end

	defp call(fun) do
		case GenServer.call(__MODULE__, {:write, fun}, @call_timeout) do
			{:ok, result} -> result
			{:error, error} -> raise error
		end
	catch
		:exit, {:noproc, _} -> run(fun, @retry_delays)
		:exit, {:timeout, _} -> raise "db writer queue timeout"
	end

	@impl true
	def init([]), do: {:ok, []}

	# Never crashes the writer itself: every error is returned to the
	# caller, retried only when it signals lock/queue contention.
	@impl true
	def handle_call({:write, fun}, _from, state) do
		{:reply, run(fun, @retry_delays), state}
	end

	defp run(fun, delays) do
		{:ok, fun.()}
	rescue
		e ->
			if retryable?(e) and delays != [] do
				[wait | rest] = delays
				Process.sleep(wait + :rand.uniform(10))
				run(fun, rest)
			else
				{:error, e}
			end
	end

	defp retryable?(%Exqlite.Error{} = e), do: String.starts_with?(Exception.message(e), "Database busy")

	defp retryable?(%DBConnection.ConnectionError{}), do: true
	defp retryable?(_), do: false
end
