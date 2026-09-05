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

  defp execute(command, session_id \\ nil) do
    params =
      %{command: command}
      |> then(&if(session_id, do: Map.put(&1, :session_id, session_id), else: &1))

    conn(:post, "/execute", Jason.encode!(params))
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
    session_id = "fast-test-#{System.unique_integer([:positive])}"
    other_session_id = "fast-other-#{System.unique_integer([:positive])}"
    previous = OptimalSystemAgent.Agent.Effort.current()
    :ok = OptimalSystemAgent.Agent.Effort.set(:medium)

    on_exit(fn ->
      OptimalSystemAgent.Agent.Effort.set(previous)
      OptimalSystemAgent.Settings.clear_session(session_id)
      OptimalSystemAgent.Settings.clear_session(other_session_id)
    end)

    body = execute("fast", session_id).resp_body |> Jason.decode!()

    assert body["effort"] == "medium"
    assert OptimalSystemAgent.Agent.Effort.current() == :medium
    assert OptimalSystemAgent.Agent.Loop.LLMClient.fast_service_tier?(session_id)
    refute OptimalSystemAgent.Agent.Loop.LLMClient.fast_service_tier?(other_session_id)

    assert OptimalSystemAgent.Agent.Loop.LLMClient.service_tier_for(%{
             provider: :openai,
             session_id: session_id
           }) == "priority"

    assert OptimalSystemAgent.Agent.Loop.LLMClient.service_tier_for(%{
             provider: :groq,
             session_id: session_id
           }) == "auto"

    assert OptimalSystemAgent.Agent.Loop.LLMClient.service_tier_for(%{
             provider: :anthropic,
             session_id: session_id
           }) == "auto"

    # A provider only gets a tier when OSA has a verified way to ask IT to go
    # faster. `openai_codex` is the sharp case: it is an OpenAI endpoint, but
    # the ChatGPT backend does not accept the `service_tier` field at all and
    # `OpenAICodex.request_opts/2` strips it, so resolving one here would be a
    # value invented for a request that will never carry it.
    for provider <- [:openai_codex, :google, :bedrock, :xai, :openrouter, :ollama] do
      assert OptimalSystemAgent.Agent.Loop.LLMClient.service_tier_for(%{
               provider: provider,
               session_id: session_id
             }) == nil
    end

    assert OptimalSystemAgent.Agent.Loop.LLMClient.service_tier_for(%{
             provider: :openai,
             session_id: other_session_id
           }) == nil

    execute("fast", session_id)
    refute OptimalSystemAgent.Agent.Loop.LLMClient.fast_service_tier?(session_id)
  end

  test "/fast says so when the current provider cannot accelerate" do
    session_id = "fast-honest-#{System.unique_integer([:positive])}"
    previous = Application.get_env(:optimal_system_agent, :default_provider)
    Application.put_env(:optimal_system_agent, :default_provider, :ollama)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_system_agent, :default_provider, previous),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      OptimalSystemAgent.Settings.clear_session(session_id)
    end)

    output = execute("fast", session_id).resp_body |> Jason.decode!() |> Map.get("output")

    # The setting really is on, so the confirmation stands...
    assert output =~ "enabled"
    assert OptimalSystemAgent.Agent.Loop.LLMClient.fast_service_tier?(session_id)

    # ...but nothing about an ollama request changes, and the user is told that
    # instead of being left to infer acceleration that never arrives.
    assert output =~ "ollama has no acceleration tier"
    assert output =~ "It takes effect on: anthropic, groq, openai"

    assert OptimalSystemAgent.Agent.Loop.LLMClient.service_tier_for(%{
             provider: :ollama,
             session_id: session_id
           }) == nil
  end

  test "/fast names the tier it will ask for when the provider can accelerate" do
    session_id = "fast-real-#{System.unique_integer([:positive])}"
    previous = Application.get_env(:optimal_system_agent, :default_provider)
    Application.put_env(:optimal_system_agent, :default_provider, :anthropic)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_system_agent, :default_provider, previous),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      OptimalSystemAgent.Settings.clear_session(session_id)
    end)

    output = execute("fast", session_id).resp_body |> Jason.decode!() |> Map.get("output")

    assert output =~ "enabled"
    assert output =~ ~s(Asking anthropic for its "auto" tier)
    refute output =~ "no acceleration tier"
  end

  test "fast-tier fallback only recognizes acceleration-specific errors" do
    refute OptimalSystemAgent.Agent.Loop.LLMClient.tier_rejection?(
             "HTTP 400: invalid tool schema"
           )

    refute OptimalSystemAgent.Agent.Loop.LLMClient.tier_rejection?("HTTP 403: account suspended")

    assert OptimalSystemAgent.Agent.Loop.LLMClient.tier_rejection?(
             "HTTP 400: service_tier priority is unavailable for this project"
           )
  end
end
