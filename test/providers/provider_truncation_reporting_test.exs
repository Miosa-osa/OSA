defmodule OptimalSystemAgent.Providers.ProviderTruncationReportingTest do
  @moduledoc """
  Providers must REPORT truncation. Everything downstream depends on it.

  Before this, three shipped providers dropped their stop reason on the floor:
  Ollama (`done_reason`), Google (`candidates[].finishReason`) and Bedrock
  (`stopReason`). Ollama is OSA's default, so on the configuration the
  reference benchmark ran under, `ReactLoop`'s entire truncation-recovery path
  was unreachable — measured on
  `bench/terminalbench/runs/osa-tb20-full89-f6981b61`.

  Both provider shapes are covered here: the STREAMING NDJSON path (which the
  agent loop actually uses) and the NON-STREAMING round-trip.

  Live verification is **blocked** — Ollama is at its session usage limit and
  every key in `.env` is empty. These run against synthetic payloads and a
  local Bandit stub, so the parsing is verified and the wire format is not.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Ollama
  alias OptimalSystemAgent.Providers.StopReason

  # ── Ollama, streaming (the path the agent loop uses) ──────────────────────

  describe "Ollama streaming — done_reason is captured from the final chunk" do
    setup do
      %{
        acc: %{
          buffer: "",
          content: "",
          tool_calls: [],
          usage: %{},
          stop_reason: nil,
          think: nil
        }
      }
    end

    test "a truncated stream reports stop_reason \"length\"", %{acc: acc} do
      line =
        Jason.encode!(%{
          "done" => true,
          "done_reason" => "length",
          "prompt_eval_count" => 1_200,
          "eval_count" => 32_768
        })

      acc = Ollama.process_ndjson_line(line, fn _ -> :ok end, acc)

      assert acc.stop_reason == "length"
      assert acc.usage.output_tokens == 32_768

      assert StopReason.truncated?(%{stop_reason: acc.stop_reason}),
             "the captured reason must read as truncation"
    end

    test "a clean stream reports stop_reason \"stop\" and is NOT truncation", %{acc: acc} do
      line =
        Jason.encode!(%{
          "done" => true,
          "done_reason" => "stop",
          "prompt_eval_count" => 1_200,
          "eval_count" => 412
        })

      acc = Ollama.process_ndjson_line(line, fn _ -> :ok end, acc)

      assert acc.stop_reason == "stop"
      refute StopReason.truncated?(%{stop_reason: acc.stop_reason})
    end

    test "done_reason is captured even when the chunk carries no token counts",
         %{acc: acc} do
      # Ollama emits exactly this shape. The usage branch skips it (nothing to
      # count); the stop reason must survive that skip — it is the more
      # important of the two facts.
      line = Jason.encode!(%{"done" => true, "done_reason" => "length"})

      acc = Ollama.process_ndjson_line(line, fn _ -> :ok end, acc)

      assert acc.stop_reason == "length"
      assert acc.usage == %{}
    end

    test "an intermediate content chunk leaves the stop reason untouched", %{acc: acc} do
      line = Jason.encode!(%{"message" => %{"content" => "hello"}})

      acc = Ollama.process_ndjson_line(line, fn _ -> :ok end, acc)

      assert acc.stop_reason == nil
      assert acc.content == "hello"
    end
  end

  # ── Ollama, non-streaming ─────────────────────────────────────────────────

  describe "Ollama non-streaming — done_reason rides the response map" do
    setup do
      prev_url = Application.get_env(:optimal_system_agent, :ollama_url)
      {server, port} = start_stub(20_910, self(), 0)
      Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:#{port}")

      on_exit(fn ->
        if prev_url,
          do: Application.put_env(:optimal_system_agent, :ollama_url, prev_url),
          else: Application.delete_env(:optimal_system_agent, :ollama_url)

        Process.exit(server, :normal)
      end)

      :ok
    end

    test "a truncated completion carries stop_reason \"length\"" do
      send(self(), :ignore)
      Process.put(:stub_done_reason, "length")

      assert {:ok, resp} =
               Ollama.chat([%{role: "user", content: "hi"}], model: "stub-model")

      assert resp.stop_reason == "length"
      assert StopReason.truncated?(resp)
    end

    test "a clean completion is not truncation" do
      Process.put(:stub_done_reason, "stop")

      assert {:ok, resp} =
               Ollama.chat([%{role: "user", content: "hi"}], model: "stub-model")

      assert resp.stop_reason == "stop"
      refute StopReason.truncated?(resp)
    end
  end

  # ── Google (Gemini), non-streaming ────────────────────────────────────────

  describe "Google — candidates[].finishReason rides the response map" do
    setup do
      prev_url = Application.get_env(:optimal_system_agent, :google_url)
      prev_key = Application.get_env(:optimal_system_agent, :google_api_key)
      {server, port} = start_stub(20_930, self(), 0)

      Application.put_env(:optimal_system_agent, :google_url, "http://127.0.0.1:#{port}")
      Application.put_env(:optimal_system_agent, :google_api_key, "test-key")

      on_exit(fn ->
        restore(:google_url, prev_url)
        restore(:google_api_key, prev_key)
        Process.exit(server, :normal)
      end)

      :ok
    end

    test "MAX_TOKENS is reported and reads as truncation" do
      Process.put(:stub_finish_reason, "MAX_TOKENS")

      assert {:ok, resp} =
               OptimalSystemAgent.Providers.Google.chat(
                 [%{role: "user", content: "hi"}],
                 model: "gemini-3.6-flash"
               )

      assert resp.stop_reason == "MAX_TOKENS"
      assert StopReason.truncated?(resp)
    end

    test "STOP is reported and is not truncation" do
      Process.put(:stub_finish_reason, "STOP")

      assert {:ok, resp} =
               OptimalSystemAgent.Providers.Google.chat(
                 [%{role: "user", content: "hi"}],
                 model: "gemini-3.6-flash"
               )

      assert resp.stop_reason == "STOP"
      refute StopReason.truncated?(resp)
    end
  end

  # ── stub plumbing ─────────────────────────────────────────────────────────
  #
  # The stub answers BOTH shapes off one plug: the request path decides whether
  # it is an Ollama `/api/chat` or a Gemini `:generateContent`. The reason to
  # echo back is threaded through the connection's query/body rather than the
  # test process dictionary, since the provider call runs in this process but
  # the plug does not.

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp start_stub(_base, _pid, attempt) when attempt > 20 do
    flunk("could not bind a stub HTTP port after 20 attempts")
  end

  defp start_stub(base, pid, attempt) do
    port = base + attempt

    # Probe first: Bandit.start_link/1 LINKS, so an :eaddrinuse would kill the
    # test process instead of returning {:error, _}.
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.StopReasonPlug, pid},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, pid, attempt + 1)
    end
  end

  defmodule StopReasonPlug do
    @moduledoc false
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, _raw, conn} = read_body(conn)

      body =
        if String.contains?(conn.request_path, "generateContent") do
          %{
            "candidates" => [
              %{
                "content" => %{"parts" => [%{"text" => "partial answ"}]},
                "finishReason" => fetch(pid, :stub_finish_reason, "STOP")
              }
            ],
            "usageMetadata" => %{"promptTokenCount" => 10, "candidatesTokenCount" => 32_768}
          }
        else
          %{
            "message" => %{"content" => "partial answ"},
            "done" => true,
            "done_reason" => fetch(pid, :stub_done_reason, "stop"),
            "prompt_eval_count" => 10,
            "eval_count" => 32_768
          }
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end

    # The provider call runs in the TEST process, so the value the test wants
    # echoed lives in that process's dictionary — reachable from the plug via
    # `Process.info/2` rather than by copying it through the request.
    defp fetch(pid, key, default) do
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> Keyword.get(dict, key, default)
        _ -> default
      end
    end
  end
end
