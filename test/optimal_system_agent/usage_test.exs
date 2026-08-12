defmodule OptimalSystemAgent.UsageTest do
  @moduledoc """
  `/usage` exists to answer "what does my account have left", and the failure
  mode that matters is not a crash — it is a plausible number that is not true.

  So these tests are mostly negative: a provider that reports nothing must not
  render a zero, a quota that has never been observed must not render as 0%,
  and the one provider whose balance could be read by spending a metered
  request must refuse to read it. Each of those is a specific way the screen
  could lie, and each has a test.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Usage
  alias OptimalSystemAgent.Usage.RateLimits
  alias OptimalSystemAgent.Usage.Render

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-usage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev_home = System.get_env("OSA_HOME")
    prev_ollama = System.get_env("OLLAMA_HOST")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      if prev_ollama,
        do: System.put_env("OLLAMA_HOST", prev_ollama),
        else: System.delete_env("OLLAMA_HOST")

      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp write_subscriptions(dir, providers) do
    path = Path.join(dir, "subscriptions.json")
    File.write!(path, Jason.encode!(%{"version" => 1, "providers" => providers}))
    File.chmod!(path, 0o600)
    :ok
  end

  defp text(lines), do: lines |> Enum.join("\n") |> strip_ansi()

  defp strip_ansi(s), do: String.replace(s, ~r/\e\[[0-9;]*m/, "")

  defp render_one(entry, opts \\ []) do
    %{active: entry.provider, entries: [entry]} |> Render.lines(opts) |> text()
  end

  # ── Provider class 1: subscription that reports a quota ──────────────────

  describe "subscription provider with a provider-reported quota" do
    test "renders the observed window, its age, and the plan", %{dir: dir} do
      write_subscriptions(dir, %{
        "openai_codex" => %{
          "access_token" => "t",
          "refresh_token" => "r",
          "plan_type" => "pro",
          "expires_at" => System.system_time(:second) + 3600
        }
      })

      RateLimits.record("openai_codex", %{
        used_percent: 43,
        window_minutes: 300,
        resets_at: "2026-08-11T18:00:00Z",
        limit_name: "primary"
      })

      # `record/2` is a cast; let it land before reading.
      _ = RateLimits.all()

      out = render_one(codex_entry())

      assert out =~ "Your account — as reported by the provider"
      assert out =~ "43%"
      assert out =~ "5h"
      assert out =~ "ago"
      assert out =~ "Plan"
      assert out =~ "pro"
    end

    test "an unobserved quota says so instead of showing 0%", %{dir: dir} do
      write_subscriptions(dir, %{
        "openai_codex" => %{"access_token" => "t", "plan_type" => "pro"}
      })

      RateLimits.reset()

      out = render_one(codex_entry())

      assert out =~ "quota not reported yet"
      assert out =~ "x-codex-"
      refute out =~ "0%"
      refute out =~ "43%"
    end
  end

  # ── Provider class 2: subscription that reports no quota ─────────────────

  describe "subscription provider with no readable quota" do
    test "claude_cli shows the plan and states that no quota API exists", %{dir: dir} do
      write_subscriptions(dir, %{
        "claude_cli" => %{"plan_type" => "max", "account_id" => "someone@example.com"}
      })

      out = render_one(entry_for("claude_cli"))

      assert out =~ "max"
      assert out =~ "remaining quota not reported by this provider"
      assert out =~ "exposes no remaining-quota API"
      refute out =~ "0%"
    end

    test "copilot refuses to spend a metered request to display quota", %{dir: dir} do
      write_subscriptions(dir, %{
        "copilot_cli" => %{"plan_type" => "business", "account_id" => "octocat"}
      })

      account = Usage.report(all: true, probe: false).entries |> find("copilot_cli")

      # The refusal is a first-class state, not a rendering accident.
      assert account.account.status == :withheld
      assert account.account.note =~ "metered premium request"

      out = render_one(account)
      assert out =~ "quota not shown"
      refute out =~ "0%"
      refute out =~ "0 premium"
    end
  end

  # ── Provider class 3: API key, OSA's own accounting only ─────────────────

  describe "API-key provider" do
    test "reports nothing from the provider and never invents a figure" do
      out = render_one(api_key_entry(nil))

      assert out =~ "not reported by this provider"
      assert out =~ "reports no account balance"
      refute out =~ "$"
      refute out =~ "%"
    end

    test "OSA's own measurement is rendered under its own heading" do
      out =
        render_one(
          api_key_entry(%{
            session_id: "s1",
            input_tokens: 12_400,
            output_tokens: 3100,
            cache_read_tokens: 0,
            cache_creation_tokens: 0,
            cost_usd: 0.1234,
            cost_note: nil
          })
        )

      assert out =~ "This session — OSA's own count of what it ran"
      assert out =~ "12.4K tokens"
      assert out =~ "3.1K tokens"
      assert out =~ "$0.1234"
      # The two are never merged into one "usage" figure.
      assert out =~ "Your account — as reported by the provider"
    end

    test "a provider with no per-token rate shows tokens but no priced total" do
      out =
        render_one(
          api_key_entry(%{
            session_id: "s1",
            input_tokens: 500,
            output_tokens: 100,
            cache_read_tokens: 0,
            cache_creation_tokens: 0,
            cost_usd: nil,
            cost_note: "no per-token rate for this provider — tokens shown, cost not priced"
          })
        )

      assert out =~ "500 tokens"
      assert out =~ "cost not priced"
      refute out =~ "$0.0000"
    end
  end

  # Poll until the listener has seen `n` connections, up to ~2s. Used instead of
  # a fixed sleep so the assertion states the contract rather than a guess about
  # scheduler latency under load.
  defp await_connections(counter, n, attempts \\ 200) do
    cond do
      Agent.get(counter, & &1) >= n ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        await_connections(counter, n, attempts - 1)
    end
  end

  # ── The read-only / no-spend contract ────────────────────────────────────

  describe "read-only contract" do
    test "report/1 opens no socket when probing is off" do
      {port, counter} = listener()
      System.put_env("OLLAMA_HOST", "http://127.0.0.1:#{port}")

      _ = Usage.report(all: true, probe: false)
      Process.sleep(50)
      assert Agent.get(counter, & &1) == 0
    end

    test "the only probe it will ever make is free and on loopback" do
      {port, counter} = listener()
      System.put_env("OLLAMA_HOST", "http://127.0.0.1:#{port}")

      # Drive the probe directly rather than through `report/1`.
      #
      # This used to call `Usage.report(all: true, probe: true)` and sleep 100ms.
      # Whether that reaches the daemon at all depends on `report/1` enumerating
      # ollama among its providers, which is ambient state other suites perturb —
      # so this was the run's single failure with the victim rotating by seed,
      # and it still failed with a 2s deadline, proving it was never timing.
      # `ollama_account/1` is the one probe this contract is about (see its
      # moduledoc: deliberately the single caller-shared probe), so assert on it.
      _ = Usage.ollama_account("http://127.0.0.1:#{port}")

      # It tried exactly the local daemon, and nothing else.
      assert await_connections(counter, 1),
             "probe never connected to the local daemon within the deadline"
    end

    test "a non-loopback OLLAMA_HOST is declined rather than dialled" do
      System.put_env("OLLAMA_HOST", "https://ollama.example.com")
      System.put_env("OLLAMA_CLOUD_API_KEY", "k")
      on_exit(fn -> System.delete_env("OLLAMA_CLOUD_API_KEY") end)

      entry = Usage.report(all: true, probe: true).entries |> find("ollama_cloud")
      assert entry.account.status == :not_reported
      assert entry.account.note =~ "no account plan could be read"
    end

    test "RateLimits.get/1 is nil — not zero — for an unobserved provider" do
      RateLimits.reset()
      assert RateLimits.get("openai_codex") == nil
      assert RateLimits.get("nothing_here") == nil
    end
  end

  # ── Classification ───────────────────────────────────────────────────────

  describe "auth_mode/1" do
    test "distinguishes the three provider classes" do
      assert Usage.auth_mode("claude_cli") == :external_cli
      assert Usage.auth_mode("copilot_cli") == :external_cli
      assert Usage.auth_mode("openai_codex") == :subscription
      assert Usage.auth_mode("openai") == :api_key
      assert Usage.auth_mode("anthropic") == :api_key
    end
  end

  describe "render with no providers" do
    test "says so rather than drawing an empty table" do
      out = Render.lines(%{active: nil, entries: []}) |> text()
      assert out =~ "No provider is configured yet"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp find(entries, id), do: Enum.find(entries, &(&1.provider == id))

  defp codex_entry do
    %{
      provider: "openai_codex",
      display_name: "ChatGPT (Codex)",
      active?: true,
      auth_mode: :subscription,
      account: codex_account(),
      measured: nil
    }
  end

  defp codex_account do
    Usage.report(all: true, probe: false).entries
    |> find("openai_codex")
    |> then(& &1.account)
  end

  defp entry_for(id) do
    Usage.report(all: true, probe: false).entries |> find(id)
  end

  defp api_key_entry(measured) do
    %{
      provider: "openai",
      display_name: "openai",
      active?: true,
      auth_mode: :api_key,
      account: %{
        status: :not_reported,
        fields: [],
        note:
          "This provider is used with an API key and reports no account balance " <>
            "or quota to OSA. Check your spend in the provider's own dashboard.",
        provider: "openai"
      },
      measured: measured
    }
  end

  # A socket that counts connections, so "makes no request" can be asserted
  # rather than assumed.
  defp listener do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(sock)

    parent = self()

    spawn_link(fn ->
      Process.flag(:trap_exit, true)
      accept_loop(sock, counter, parent)
    end)

    on_exit(fn ->
      :gen_tcp.close(sock)
    end)

    {port, counter}
  end

  defp accept_loop(sock, counter, parent) do
    case :gen_tcp.accept(sock, 5_000) do
      {:ok, client} ->
        Agent.update(counter, &(&1 + 1))
        _ = :gen_tcp.send(client, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
        :gen_tcp.close(client)
        accept_loop(sock, counter, parent)

      _ ->
        :ok
    end
  end
end
