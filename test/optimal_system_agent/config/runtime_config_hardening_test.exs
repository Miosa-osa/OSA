defmodule OptimalSystemAgent.RuntimeConfigHardeningTest do
  @moduledoc """
  Regression tests for runtime.exs env-var parsing hardening (findings 5, 6, 7).

  An exported-but-empty or non-numeric env var (EMAIL_IMAP_PORT="", POOL_SIZE=
  "abc") previously hit String.to_integer/1 directly and raised ArgumentError at
  runtime-config load — crashing node boot even when the feature is never used.
  These now route through the parse_int fallback. A 4-part but non-numeric /
  out-of-range OSA_HTTP_IP no longer crashes either.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("config/runtime.exs", File.cwd!())

  # Read runtime.exs as prod config with the given env overrides applied, then
  # fully restore the process environment so the loader's .env side effects and
  # our overrides never leak into the rest of the suite.
  defp read_with_env(overrides) do
    snapshot = System.get_env()
    Enum.each(overrides, fn {k, v} -> System.put_env(k, v) end)

    try do
      Config.Reader.read!(@runtime, env: :prod)
    after
      # Delete anything added, restore anything changed/removed.
      System.get_env()
      |> Map.keys()
      |> Enum.each(fn k -> unless Map.has_key?(snapshot, k), do: System.delete_env(k) end)

      Enum.each(snapshot, fn {k, v} -> System.put_env(k, v) end)
    end
  end

  test "empty EMAIL_IMAP_PORT falls back to the default instead of crashing" do
    cfg = read_with_env(%{"EMAIL_IMAP_PORT" => ""})
    assert cfg[:optimal_system_agent][:email_imap_port] == 993
  end

  test "non-numeric EMAIL_SMTP_PORT / EMAIL_POLL_INTERVAL fall back to defaults" do
    cfg = read_with_env(%{"EMAIL_SMTP_PORT" => "abc", "EMAIL_POLL_INTERVAL" => ""})
    assert cfg[:optimal_system_agent][:email_smtp_port] == 587
    assert cfg[:optimal_system_agent][:email_poll_interval] == 15
  end

  test "empty POOL_SIZE with DATABASE_URL set falls back to 10 instead of crashing" do
    cfg =
      read_with_env(%{
        "DATABASE_URL" => "postgres://user:pass@localhost:5432/db",
        "POOL_SIZE" => ""
      })

    repo_cfg = cfg[:optimal_system_agent][OptimalSystemAgent.Platform.Repo]
    assert repo_cfg[:pool_size] == 10
  end

  test "4-part non-numeric OSA_HTTP_IP falls back to loopback instead of crashing" do
    cfg = read_with_env(%{"OSA_HTTP_IP" => "a.b.c.d"})
    assert cfg[:optimal_system_agent][:http_ip] == {127, 0, 0, 1}
  end

  test "out-of-range OSA_HTTP_IP octets fall back to loopback" do
    cfg = read_with_env(%{"OSA_HTTP_IP" => "999.1.1.1"})
    assert cfg[:optimal_system_agent][:http_ip] == {127, 0, 0, 1}
  end

  test "a valid OSA_HTTP_IP still parses to its tuple" do
    cfg = read_with_env(%{"OSA_HTTP_IP" => "10.0.0.5"})
    assert cfg[:optimal_system_agent][:http_ip] == {10, 0, 0, 5}
  end
end
