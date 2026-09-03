defmodule OptimalSystemAgent.Channels.HTTP.CommandExecuteTest do
  @moduledoc """
  Regression guard for `POST /api/v1/commands/execute` (mounted here as `/execute`), the endpoint every slash
  command reaches over HTTP — and therefore from the TUI, which posts here for
  any command it does not handle locally.

  The handler captures a command's output by swapping the group leader for a
  `StringIO` and reading it back. `StringIO.close/1` returns
  `{:ok, {input, output}}`, but the handler destructured it as `{_, captured}`.
  That MATCHES — `_` binds `:ok` and `captured` binds the inner `{input, output}`
  TUPLE — so nothing failed at the match. It failed one step later, on

      output |> String.replace(~r/\\e\\[[0-9;]*m/, "")

  with a `FunctionClauseError`, because `String.replace/3` has no tuple clause.
  And that line sits OUTSIDE the surrounding `try/rescue`, so it was never
  converted to an error string — it escaped as a 500 for every slash command.

  The bug is invisible to a "does it return 200" smoke test only if the response
  is never decoded, which is why this asserts on the body shape: `output` must be
  a STRING. That is the property the tuple violates.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes

  @opts ToolRoutes.init([])

  setup do
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    Application.put_env(:optimal_system_agent, :require_auth, false)

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:optimal_system_agent, :require_auth, original_auth),
        else: Application.delete_env(:optimal_system_agent, :require_auth)
    end)

    :ok
  end

  defp execute(command) do
    conn(:post, "/execute", Jason.encode!(%{command: command}))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> ToolRoutes.call(@opts)
  end

  test "a slash command returns 200 with a STRING output, not a captured tuple" do
    conn = execute("/help")

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)

    assert is_binary(body["output"]),
           "output must be the captured string; got #{inspect(body["output"])}"

    assert body["command"] == "/help"
  end

  test "captured output has ANSI colour codes stripped" do
    conn = execute("/help")

    body = Jason.decode!(conn.resp_body)

    refute String.contains?(body["output"], "\e["),
           "escape sequences must be stripped before the JSON response"
  end

  test "an unknown command still answers 200 with a string rather than crashing" do
    # The capture path runs identically for a command that dispatch/2 rejects,
    # so this pins the same destructure without depending on /help's content.
    conn = execute("/definitely-not-a-real-command")

    assert conn.status == 200
    assert is_binary(Jason.decode!(conn.resp_body)["output"])
  end

  test "/fast enables OpenAI priority processing without changing effort" do
    previous = OptimalSystemAgent.Agent.Effort.current()
    previous_fast = OptimalSystemAgent.Agent.Loop.LLMClient.fast_service_tier?()
    :ok = OptimalSystemAgent.Agent.Effort.set(:medium)

    on_exit(fn ->
      OptimalSystemAgent.Agent.Effort.set(previous)

      if OptimalSystemAgent.Agent.Loop.LLMClient.fast_service_tier?() != previous_fast do
        OptimalSystemAgent.Agent.Loop.LLMClient.toggle_fast_service_tier()
      end
    end)

    if previous_fast, do: OptimalSystemAgent.Agent.Loop.LLMClient.toggle_fast_service_tier()

    body = execute("fast").resp_body |> Jason.decode!()

    assert body["effort"] == "medium"
    assert OptimalSystemAgent.Agent.Effort.current() == :medium
    assert OptimalSystemAgent.Agent.Loop.LLMClient.fast_service_tier?()
  end
end
