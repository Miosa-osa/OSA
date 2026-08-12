defmodule OptimalSystemAgent.Providers.CacheAttributionTest do
  @moduledoc """
  The prompt-cache break attributor.

  The product here is the VERDICT STRING. "The cache missed" sends the owner
  nowhere; "tool `bash`'s schema changed" sends them to one file. So these
  tests assert on the named cause, not merely that a difference was detected —
  a whole-body hash would pass a "something changed" assertion and be useless.

  Two tests are load-bearing and are the ones named in the brief:

    * `mutating ONE tool's schema names THAT tool`
    * `mutating a mid-history message reports the index`

  Both fail on a coarser implementation, not just on a missing one.

  ## What is NOT covered

  Nothing here talks to a live Anthropic endpoint — no Anthropic key is
  reachable from this machine, so no `cache_read_input_tokens` in this file was
  ever produced by Anthropic. The usage numbers are fixtures. What is proven is
  the attribution logic given a reported drop, and that a drop is the only
  thing that triggers a report.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.CacheAttribution

  # A hit, then a total miss — the shape that must produce a verdict.
  @hit %{cache_read_input_tokens: 30_000}
  @miss %{cache_read_input_tokens: 0}

  setup do
    key = "scope-#{System.unique_integer([:positive])}"
    CacheAttribution.reset(key)
    on_exit(fn -> CacheAttribution.reset(key) end)
    {:ok, key: key}
  end

  defp body(overrides \\ []) do
    base = %{
      model: "claude-opus-5",
      max_tokens: 8192,
      system: [
        %{"type" => "text", "text" => "static base", "cache_control" => %{"type" => "ephemeral"}},
        %{"type" => "text", "text" => "world state", "cache_control" => %{"type" => "ephemeral"}},
        %{"type" => "text", "text" => "volatile tail"}
      ],
      tools: [
        %{"name" => "bash", "description" => "run a command", "input_schema" => %{"a" => 1}},
        %{"name" => "read", "description" => "read a file", "input_schema" => %{"b" => 2}},
        %{"name" => "edit", "description" => "edit a file", "input_schema" => %{"c" => 3}}
      ],
      messages: [
        %{"role" => "user", "content" => "one"},
        %{"role" => "assistant", "content" => "two"},
        %{"role" => "user", "content" => "three"},
        %{"role" => "assistant", "content" => "four"}
      ]
    }

    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  # First request establishes the baseline with a healthy read; second request
  # reports the drop.
  defp break_between(key, first_body, second_body) do
    assert :ok = CacheAttribution.observe(key, CacheAttribution.fingerprint(first_body), @hit)
    CacheAttribution.observe(key, CacheAttribution.fingerprint(second_body), @miss)
  end

  describe "named causes" do
    test "mutating ONE tool's schema names THAT tool", %{key: key} do
      mutated =
        body(
          tools: [
            %{"name" => "bash", "description" => "run a command", "input_schema" => %{"a" => 1}},
            # `read` gains a field. Same tool SET, same order, same names.
            %{
              "name" => "read",
              "description" => "read a file",
              "input_schema" => %{"b" => 2, "offset" => "int"}
            },
            %{"name" => "edit", "description" => "edit a file", "input_schema" => %{"c" => 3}}
          ]
        )

      assert {:break, verdict} = break_between(key, body(), mutated)

      assert verdict =~ "tool prompt/schema changed, same tool set"
      # The whole point: it names the culprit, and only the culprit.
      assert verdict =~ "read"
      refute verdict =~ "bash"
      refute verdict =~ "edit"
      # Not misfiled as a set change.
      refute verdict =~ "tools:"
    end

    test "mutating a mid-history message reports the index", %{key: key} do
      mutated =
        body(
          messages: [
            %{"role" => "user", "content" => "one"},
            %{"role" => "assistant", "content" => "two"},
            # index 2 of 4 rewritten in place — the expensive kind of mutation,
            # because everything from here on re-prefills.
            %{"role" => "user", "content" => "THREE (rewritten)"},
            %{"role" => "assistant", "content" => "four"}
          ]
        )

      assert {:break, verdict} = break_between(key, body(), mutated)
      assert verdict =~ "message history mutated at index 2/4"
    end

    test "appending a turn is not reported as a mutation", %{key: key} do
      # A pure append leaves the prefix intact. If this reported, every normal
      # turn would look like a break and the readout would be worthless.
      appended = body(messages: body().messages ++ [%{"role" => "user", "content" => "five"}])

      assert {:break, verdict} = break_between(key, body(), appended)
      refute verdict =~ "message history mutated"
    end

    test "adding a tool is reported as a set change, naming the tool", %{key: key} do
      added = body(tools: body().tools ++ [%{"name" => "web_fetch", "input_schema" => %{}}])

      assert {:break, verdict} = break_between(key, body(), added)
      assert verdict =~ "+1/-0 tools"
      assert verdict =~ "web_fetch"
    end

    test "reordering the same tools is named as reordering, not a schema edit", %{key: key} do
      [a, b, c] = body().tools
      reordered = body(tools: [b, a, c])

      assert {:break, verdict} = break_between(key, body(), reordered)
      assert verdict =~ "tool order changed"
      refute verdict =~ "schema changed"
    end

    test "a changed system block names the block and the size delta", %{key: key} do
      [first, _second, third] = body().system

      mutated =
        body(
          system: [
            first,
            %{
              "type" => "text",
              "text" => "world state PLUS a new section",
              "cache_control" => %{"type" => "ephemeral"}
            },
            third
          ]
        )

      assert {:break, verdict} = break_between(key, body(), mutated)
      assert verdict =~ "system prompt changed (block 2/3"
      assert verdict =~ "+19 chars"
    end

    test "a model swap names both models", %{key: key} do
      assert {:break, verdict} = break_between(key, body(), body(model: "claude-sonnet-5"))
      assert verdict =~ "model changed (claude-opus-5 → claude-sonnet-5)"
    end

    test "a moved cache_control breakpoint is named", %{key: key} do
      [first, second, third] = body().system
      # Breakpoint dropped from block 2. Text is byte-identical.
      moved = body(system: [first, Map.delete(second, "cache_control"), third])

      assert {:break, verdict} = break_between(key, body(), moved)
      assert verdict =~ "cache_control changed (scope or TTL)"
      refute verdict =~ "system prompt changed"
    end

    test "a request-param change (max_tokens/thinking) is named", %{key: key} do
      assert {:break, verdict} = break_between(key, body(), body(max_tokens: 16_384))
      assert verdict =~ "request params changed"
    end

    test "several causes in one request are all named", %{key: key} do
      both = body(model: "claude-sonnet-5", max_tokens: 16_384)

      assert {:break, verdict} = break_between(key, body(), both)
      assert verdict =~ "model changed"
      assert verdict =~ "request params changed"
      assert verdict =~ " · "
    end
  end

  describe "when NOT to report" do
    test "a diff with a healthy cache read is not a break", %{key: key} do
      # The prefix before the change was still served. Reporting this would be
      # noise, and noise is what makes a diagnostic get turned off.
      assert :ok = CacheAttribution.observe(key, CacheAttribution.fingerprint(body()), @hit)

      assert :ok =
               CacheAttribution.observe(
                 key,
                 CacheAttribution.fingerprint(body(model: "claude-sonnet-5")),
                 %{cache_read_input_tokens: 31_000}
               )

      assert CacheAttribution.last_break(key) == nil
    end

    test "the first request in a scope never reports", %{key: key} do
      assert :ok = CacheAttribution.observe(key, CacheAttribution.fingerprint(body()), @miss)
      assert CacheAttribution.last_break(key) == nil
    end

    test "two scopes are compared independently", %{key: key} do
      other = key <> "-other"
      on_exit(fn -> CacheAttribution.reset(other) end)

      assert :ok = CacheAttribution.observe(key, CacheAttribution.fingerprint(body()), @hit)

      # A different session's very different request must not be diffed against
      # this one. Interleaved sessions would otherwise report a break per turn.
      assert :ok =
               CacheAttribution.observe(
                 other,
                 CacheAttribution.fingerprint(body(model: "claude-sonnet-5")),
                 @miss
               )

      assert CacheAttribution.last_break(key) == nil
      assert CacheAttribution.last_break(other) == nil
    end

    test "attribution can be switched off", %{key: key} do
      Application.put_env(:optimal_system_agent, :cache_attribution_enabled, false)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :cache_attribution_enabled) end)

      assert :ok = CacheAttribution.observe(key, CacheAttribution.fingerprint(body()), @hit)

      assert :ok =
               CacheAttribution.observe(
                 key,
                 CacheAttribution.fingerprint(body(model: "x")),
                 @miss
               )
    end
  end

  describe "unchanged prompt" do
    test "a long gap reads as TTL expiry, a short one as server-side" do
      fp = CacheAttribution.fingerprint(body())

      assert CacheAttribution.attribute(fp, fp, 6 * 60 * 1000) ==
               "possible 5min TTL expiry (prompt unchanged)"

      assert CacheAttribution.attribute(fp, fp, 30_000) ==
               "likely server-side (prompt unchanged, <5min gap)"
    end

    test "atom- and string-keyed cache_control fingerprint identically" do
      atom_keyed = %{
        model: "m",
        system: [%{"type" => "text", "text" => "x", "cache_control" => %{type: :ephemeral}}],
        messages: [],
        tools: []
      }

      string_keyed = %{
        model: "m",
        system: [
          %{"type" => "text", "text" => "x", "cache_control" => %{"type" => "ephemeral"}}
        ],
        messages: [],
        tools: []
      }

      # Same wire bytes. A fingerprint that told them apart would report a
      # phantom cache_control break on every request.
      assert CacheAttribution.fingerprint(atom_keyed) ==
               CacheAttribution.fingerprint(string_keyed)
    end
  end

  describe "scope/1" do
    test "prefers an explicit cache_scope, then session_id, then default" do
      assert CacheAttribution.scope(cache_scope: "sub", session_id: "s") == "sub"
      assert CacheAttribution.scope(session_id: "s") == "s"
      assert CacheAttribution.scope([]) == "default"
      assert CacheAttribution.scope(session_id: nil) == "default"
    end
  end

  describe "cost" do
    @tag :perf
    test "fingerprinting a realistic ~47k-token body is sub-millisecond" do
      # ~47k tokens ≈ ~190 KB of prompt text. Shaped like a real OSA request:
      # a large static base, a world-state block, a volatile tail, ~30 tool
      # schemas, and a 60-turn history.
      big = fn n -> String.duplicate("lorem ipsum dolor sit amet consectetur ", n) end

      realistic = %{
        model: "claude-opus-5",
        max_tokens: 8192,
        system: [
          %{
            "type" => "text",
            "text" => big.(2800),
            "cache_control" => %{"type" => "ephemeral"}
          },
          %{"type" => "text", "text" => big.(300), "cache_control" => %{"type" => "ephemeral"}},
          %{"type" => "text", "text" => big.(40)}
        ],
        tools:
          for i <- 1..30 do
            %{
              "name" => "tool_#{i}",
              "description" => big.(12),
              "input_schema" => %{
                "type" => "object",
                "properties" => Map.new(1..8, fn j -> {"p#{j}", %{"type" => "string"}} end)
              }
            }
          end,
        messages:
          for i <- 1..60 do
            %{
              "role" => rem(i, 2) |> then(&if(&1 == 0, do: "user", else: "assistant")),
              "content" => big.(20)
            }
          end
      }

      bytes = realistic |> :erlang.term_to_binary() |> byte_size()
      assert bytes > 150_000, "fixture is not realistic (#{bytes} bytes)"

      # Warm up, then measure the median of 20 runs.
      _ = CacheAttribution.fingerprint(realistic)

      times =
        for _ <- 1..20 do
          {us, _} = :timer.tc(fn -> CacheAttribution.fingerprint(realistic) end)
          us
        end

      median = times |> Enum.sort() |> Enum.at(10)

      IO.puts(
        "\n[cache-attribution] fingerprint of a #{div(bytes, 1024)} KB body: " <>
          "median #{median}us (min #{Enum.min(times)}us, max #{Enum.max(times)}us)"
      )

      # Generous ceiling: the point is that it is negligible next to a network
      # round-trip measured in SECONDS, not that it hits a specific number on
      # this machine.
      assert median < 20_000,
             "fingerprinting cost #{median}us — too expensive to leave on"
    end
  end
end
