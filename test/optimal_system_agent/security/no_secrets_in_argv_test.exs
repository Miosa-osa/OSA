defmodule OptimalSystemAgent.Security.NoSecretsInArgvTest do
  @moduledoc """
  A credential must never appear in a spawned process's **argv**.

  On Linux `/proc/<pid>/cmdline` is world-readable and `ps` shows the full
  argument vector to every local user on the machine. Two call sites put a live
  secret there:

    * `providers/ollama.ex` — the Ollama Cloud bearer token, as
      `-H "Authorization: Bearer <token>"`, on **every single request**;
    * `open_computers/.../gha_runner.ex` — the GitHub Actions runner
      registration token, as `--token <token>`.

  Both now route the credential out of argv — a 0600 curl config file and an
  `ACTIONS_RUNNER_INPUT_TOKEN` environment variable respectively (a process's
  environment block is owner-readable only).

  These tests assert on the **constructed command**, not on whether the request
  succeeds: a request that works while leaking the token is exactly the bug.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Ollama

  @secret "osa-cloud-key-DO-NOT-LEAK-9f3c1a"

  describe "Ollama Cloud: the bearer token never reaches argv" do
    test "argv carries no part of the key and no Authorization header" do
      args = Ollama.curl_args("/tmp/cfg.conf", "/tmp/body.json", "https://ollama.com")
      joined = Enum.join(args, " ")

      refute joined =~ @secret
      refute joined =~ "Authorization"
      refute joined =~ "Bearer"

      # And nothing secret-shaped anywhere in the vector.
      for arg <- args do
        refute arg =~ ~r/Bearer\s/
        refute arg =~ ~r/^sk-/
      end
    end

    test "argv still builds the request it is supposed to build" do
      args = Ollama.curl_args("/tmp/cfg.conf", "/tmp/body.json", "https://ollama.com")

      assert "--config" in args
      assert "/tmp/cfg.conf" in args
      assert "@/tmp/body.json" in args
      assert "https://ollama.com/api/chat" in args
      assert "Content-Type: application/json" in args
    end

    test "the key goes into the curl config file instead" do
      config = Ollama.curl_config(@secret)

      assert config =~ "Authorization: Bearer #{@secret}"
      assert config =~ ~r/^header = /
    end

    test "no key means no Authorization line at all (local/keyless setups)" do
      assert Ollama.curl_config("") == ""
      assert Ollama.curl_config(nil) == ""
    end

    test "a key containing quotes or backslashes cannot break out of the config value" do
      config = Ollama.curl_config(~S(we"ird\key))
      assert config == ~S|header = "Authorization: Bearer we\"ird\\key"| <> "\n"
    end
  end

  describe "GitHub Actions runner: the registration token never reaches argv" do
    # `configure_runner/2` is private and shells out, so assert on the source of
    # the call site: the token must not be adjacent to a `--token` argv flag,
    # and must be handed over through the environment.
    @gha_runner "lib/optimal_system_agent/open_computers/executor/direct/gha_runner.ex"

    test "config.sh is not passed --token" do
      source = File.read!(@gha_runner)
      refute source =~ ~s("--token"), "the registration token must not be an argv element"
    end

    test "the token is passed through the process environment instead" do
      source = File.read!(@gha_runner)
      assert source =~ "ACTIONS_RUNNER_INPUT_TOKEN"
      assert source =~ "payload.registration_token"
      assert source =~ ~r/env:\s*env/
    end
  end

  describe "tree-wide: no credential is interpolated into a command or argv" do
    # The class, not the instance. Flags any `System.cmd`/`Port.open` argument
    # list or shell string that interpolates a secret-named binding.
    @secret_binding ~r/#\{[^}]*\b(?:api_key|apikey|token|secret|password|passwd|credential)\w*\b[^}]*\}/i

    # An argv element carrying a credential is the bug. A 0600 *config file*
    # whose CONTENT is `header = "Authorization: Bearer …"` is the fix, so the
    # scanner keys off the `-H`/`--header` argv flag that precedes or shares
    # the line, not on the word "Authorization" alone.
    @header_flag ~r/"-H"|"--header"|--header\s|-H\s/

    test "no Authorization/Bearer header is built as an argv element" do
      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          lines = file |> File.read!() |> String.split("\n")

          lines
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, n} ->
            prev = Enum.at(lines, n - 2, "")

            String.match?(line, ~r/"(?:Authorization|authorization):\s/) and
              String.match?(line, @secret_binding) and
              (String.match?(line, @header_flag) or String.match?(prev, @header_flag))
          end)
          |> Enum.map(fn {line, n} -> "#{file}:#{n}: #{String.trim(line)}" end)
        end)

      assert offenders == [],
             "a credential is being interpolated into a spawned command's argv:\n" <>
               Enum.join(offenders, "\n")
    end

    test "no System.cmd argument list interpolates a secret-named binding" do
      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          lines = file |> File.read!() |> String.split("\n")

          lines
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _n} ->
            String.contains?(line, "System.cmd(") and String.match?(line, @secret_binding)
          end)
          |> Enum.map(fn {line, n} -> "#{file}:#{n}: #{String.trim(line)}" end)
        end)

      assert offenders == [],
             "a credential is being interpolated into System.cmd/3:\n" <>
               Enum.join(offenders, "\n")
    end
  end
end
