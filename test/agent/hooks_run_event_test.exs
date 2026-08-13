defmodule OptimalSystemAgent.Agent.HooksRunEventTest do
  @moduledoc """
  Every hook invocation reports what it did.

  The interesting case is that a crash and a deliberate `:skip` used to be
  indistinguishable from outside `invoke/3` — both left it as a bare `:skip` —
  so "how many hooks failed" was not answerable from the dispatcher at all.
  These pin the distinction, and pin that the chain's own behaviour did not
  change while the reporting was added.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Events.Bus

  @event :pre_tool_use

  setup do
    if Process.whereis(Hooks) do
      baseline = hook_key_set()

      test = self()

      ref =
        Bus.register_handler(:system_event, fn payload ->
          data = if is_map(payload[:data]), do: payload[:data], else: payload

          if data[:event] == :hook_run do
            send(test, {:hook_run, data})
          end

          :ok
        end)

      on_exit(fn ->
        Bus.unregister_handler(:system_event, ref)

        for {event, name} <- MapSet.difference(hook_key_set(), baseline) do
          Hooks.unregister(event, name)
        end
      end)

      {:ok, %{available: true}}
    else
      {:ok, %{available: false}}
    end
  end

  defp hook_key_set do
    Hooks.list_hooks()
    |> Enum.flat_map(fn {event, hooks} -> Enum.map(hooks, &{event, &1.name}) end)
    |> MapSet.new()
  end

  defp await_run(name) do
    receive do
      {:hook_run, %{hook_name: ^name} = data} -> data
    after
      2_000 ->
        seen =
          Stream.repeatedly(fn ->
            receive do
              {:hook_run, d} -> d[:hook_name]
            after
              0 -> nil
            end
          end)
          |> Enum.take_while(& &1)

        flunk("no hook_run for #{name}; saw: #{inspect(seen)}")
    end
  end

  defp payload, do: %{session_id: "sess-hook-run", tool: "Bash", arguments: %{}}

  # `Hooks.register/4` is a `GenServer.cast` while `Hooks.run/2` executes in the
  # CALLER's process, so registering and immediately running is a race the test
  # loses intermittently — the hook is not in the chain yet and only the
  # pre-registered built-ins run. Reading the registry back is a `call`, which
  # flushes the cast ahead of it.
  defp register_and_sync(name, fun) do
    Hooks.register(@event, name, fun)
    wait_until_registered(name, 50)
  end

  defp wait_until_registered(name, 0), do: flunk("#{name} never reached the hook registry")

  defp wait_until_registered(name, tries) do
    if MapSet.member?(hook_key_set(), {@event, name}) do
      :ok
    else
      Process.sleep(10)
      wait_until_registered(name, tries - 1)
    end
  end

  test "a hook that succeeds reports ok", ctx do
    if ctx.available do
      register_and_sync("run-ok", fn _ -> :allow end)
      assert {:ok, _} = Hooks.run(@event, payload())
      assert %{outcome: :ok} = await_run("run-ok")
    end
  end

  test "a hook that crashes reports crashed, and the chain still continues", ctx do
    if ctx.available do
      register_and_sync("run-boom", fn _ -> raise "boom" end)
      # The chain must be unaffected: a broken hook has never been allowed to
      # take the turn down with it, and adding reporting must not change that.
      assert {:ok, _} = Hooks.run(@event, payload())
      assert %{outcome: :crashed} = await_run("run-boom")
    end
  end

  test "a hook that returns skip is not a failure", ctx do
    if ctx.available do
      # The case that motivated the whole change: `:skip` is a hook declining to
      # have an opinion. Counting it as a failure would report a healthy setup
      # as broken.
      register_and_sync("run-skip", fn _ -> :skip end)
      assert {:ok, _} = Hooks.run(@event, payload())
      assert %{outcome: :ok} = await_run("run-skip")
    end
  end

  test "a hook that blocks reports blocked, which is not failed", ctx do
    if ctx.available do
      register_and_sync("run-block", fn _ -> {:block, "nope"} end)
      assert {:blocked, "nope"} = Hooks.run(@event, payload())
      assert %{outcome: :blocked} = await_run("run-block")
    end
  end

  test "the report carries the session id it must be routed by", ctx do
    if ctx.available do
      # Without this the event cannot reach any TUI: the forwarder drops
      # anything it cannot address to a session topic.
      register_and_sync("run-routed", fn _ -> :allow end)
      Hooks.run(@event, payload())
      assert %{session_id: "sess-hook-run", hook_event: @event} = await_run("run-routed")
    end
  end
end
