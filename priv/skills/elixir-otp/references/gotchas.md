# OTP, configuration, and integration pitfalls

## GenServer lifecycle and message ordering

Return the callback tuple appropriate to the callback: synchronous calls can
reply, casts cannot. `init/1` initializes state. If you implement `handle_info/2`,
cover the messages the process can receive, including monitor and timer events.
`use GenServer` supplies a default for an omitted `handle_info/2`; it is inaccurate
to say every unhandled message always crashes every server. A custom callback
without a matching clause can crash. Use `@impl true` for implemented callbacks.

```elixir-run
defmodule SkillOtpCounter do
  use GenServer
  @impl true
  def init(count), do: {:ok, count}
  @impl true
  def handle_call(:read, _from, count), do: {:reply, count, count}
  @impl true
  def handle_cast(:increment, count), do: {:noreply, count + 1}
  @impl true
  def handle_info(_message, count), do: {:noreply, count}

  def run do
    {:ok, pid} = GenServer.start_link(__MODULE__, 0)
    try do
      0 = GenServer.call(pid, :read)
      GenServer.cast(pid, :increment)
      1 = GenServer.call(pid, :read)
      send(pid, :unknown)
      1 = GenServer.call(pid, :read)
    after
      GenServer.stop(pid)
    end
    false = Process.alive?(pid)
  end
end
```

Messages from the same sender to the same receiver retain ordering. Do not
assume ordering between different senders. Test supervision and restart behavior
in the actual application's supervision tree when changing child specs.

## Tasks, links, monitors, and cleanup

`Task.async/1` links its task to the caller; an abnormal task exit can terminate
the caller. Await a task and choose a bounded timeout. For work whose failure
should not kill its owner, use a Task.Supervisor and `async_nolink/2`. Handle
error/timeout outcomes and stop outstanding work. Do not leave monitored tasks
running merely because the caller stopped waiting.

```elixir-run
{:ok, supervisor} = Task.Supervisor.start_link()
try do
  task = Task.Supervisor.async_nolink(supervisor, fn -> 21 * 2 end)
  {:ok, 42} = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
after
  Supervisor.stop(supervisor)
end
```

## Runtime versus compile-time configuration

`Application.get_env/3` is valid for optional settings with defaults;
`Application.fetch_env!/2` is appropriate when missing configuration is an error.
Use `Application.compile_env/3` for intentional compile-time configuration and
runtime reads for values that should change after compilation. Module attributes
are evaluated at compilation; `@now System.system_time()` is not a live clock.
Follow the project's configuration conventions rather than banning a valid API.

## Exceptions, scope, and cleanup

Return tagged errors for expected failures. Raise for violated contracts when
that is the API's convention. Use `try/rescue` at an appropriate boundary;
variables inside its clauses are not available outside. `after` handles ordinary
cleanup during stack unwinding; a killed VM cannot be expected to run it.

```elixir-run
outcome =
  try do
    raise ArgumentError, "expected fixture error"
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end
{:error, "expected fixture error"} = outcome
```

## Ecto and Phoenix boundaries

`Ecto.Changeset.apply_changes/1` returns in-memory data; it does not persist or
prove validation succeeded. `Repo.insert/2` accepts a struct or changeset;
use a changeset for validation of external params. `Repo.update/2` takes a
changeset. Handle `{:ok, record}` and `{:error, changeset}`, then assert a database
reread when testing persistence. `validate_required/3` checks values in changes
or existing data, and its options default allows the usual two-argument call.
A `unique_constraint/3` check depends on the matching database constraint.

Phoenix controller branches must ultimately return a connection. Explicitly
handle absent records, invalid params, and authorization failures. Test the
HTTP status and response, not just a helper's return value. These integration
notes require the repository's real Ecto/Phoenix test environment; the stdlib
snippet verifier does not validate database or controller behavior.

## Verification commands

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/path_test.exs
```

Use `mix help xref` to see supported cross-reference commands for the installed
Mix version. Do not prescribe obsolete commands as a substitute for executing
the affected code path.
