defmodule OptimalSystemAgent.Providers.WireEncodingBackstopTest do
  @moduledoc """
  The provider-boundary guarantee: NO message list, however it was built, can
  reach a JSON encoder carrying bytes that encoder will refuse.

  Sanitizing in the tools is necessary but cannot be sufficient. There are
  dozens of built-in tools, plus MCP servers and plugins OSA does not own, and
  every one of them is one `File.read/1` from re-introducing this. Two previous
  attempts at this bug fixed the shell path and left the file tools broken; a
  fix that can only be complete by enumeration is a fix that will be incomplete
  again.

  So the guarantee is asserted HERE, at
  `Registry.normalize_outbound_messages/3`, which every provider dispatch
  (`do_apply_provider/3`, `do_native_stream/4`, `do_try_stream_provider/4`)
  passes through.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers
  alias OptimalSystemAgent.Providers.ErrorCatalog
  alias OptimalSystemAgent.Providers.Registry
  alias OptimalSystemAgent.Utils.WireEncoding

  # `0xDA` standing alone is not legal UTF-8. This exact byte is the one
  # observed in the field, from a latin-1 source file.
  @bad <<0xDA>>

  defp targets, do: [Providers.Anthropic, {:compat, :openrouter}, Providers.Ollama]

  defp encodable!(messages) do
    assert Jason.encode_to_iodata!(%{model: "m", messages: messages})
  end

  # ── The exact failure, at the boundary ──────────────────────────────────

  describe "the reproduction" do
    test "an unsanitized tool result is what Jason refuses" do
      poisoned = "src/app.py:401:x = \"" <> @bad <> "ltimo\""

      assert_raise Jason.EncodeError, ~r/invalid byte 0xDA/, fn ->
        Jason.encode_to_iodata!(%{messages: [%{role: "tool", content: poisoned}]})
      end
    end

    test "the same result survives the provider boundary for every dispatch target" do
      poisoned = "src/app.py:401:x = \"" <> @bad <> "ltimo\""
      messages = [%{role: "user", content: "go"}, %{role: "tool", content: poisoned}]

      for target <- targets() do
        out = Registry.normalize_outbound_messages(messages, target, model: "m")
        encodable!(out)
      end
    end
  end

  # ── Shape coverage: the reason this is a term walk, not a field list ────

  describe "every shape a tool result can arrive in" do
    test "string content" do
      for target <- targets() do
        [%{role: "tool", content: "ok" <> @bad}]
        |> Registry.normalize_outbound_messages(target, model: "m")
        |> encodable!()
      end
    end

    test "structured content blocks" do
      messages = [
        %{
          role: "user",
          content: [
            %{"type" => "text", "text" => "grep said: " <> @bad},
            %{"type" => "text", "text" => "still fine"}
          ]
        }
      ]

      for target <- targets() do
        messages |> Registry.normalize_outbound_messages(target, model: "m") |> encodable!()
      end
    end

    test "tool-call arguments, nested arbitrarily deep" do
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              id: "t1",
              name: "file_write",
              arguments: %{"content" => %{"nested" => ["a", "b" <> @bad]}}
            }
          ]
        }
      ]

      for target <- targets() do
        messages |> Registry.normalize_outbound_messages(target, model: "m") |> encodable!()
      end
    end

    test "string-keyed messages rehydrated from a persisted session" do
      messages = [%{"role" => "tool", "content" => "x" <> @bad, "tool_call_id" => "c1"}]

      for target <- targets() do
        messages |> Registry.normalize_outbound_messages(target, model: "m") |> encodable!()
      end
    end

    test "a poisoned MAP KEY — a shape no field allowlist would cover" do
      messages = [%{role: "tool", content: %{("k" <> @bad) => "v"}}]

      for target <- targets() do
        messages |> Registry.normalize_outbound_messages(target, model: "m") |> encodable!()
      end
    end
  end

  # ── The normal path must be untouched ───────────────────────────────────

  describe "clean input" do
    test "is returned as the IDENTICAL term — no rebuild, no allocation" do
      messages = [%{role: "user", content: "naïve 日本語 🙈 Ω≈ç√"}]
      assert WireEncoding.scrub_messages(messages) === messages
    end

    test "valid UTF-8 with unusual codepoints is preserved byte-for-byte" do
      exotic = "naïve — 日本語 — 🙈🙉🙊 — Ω≈ç√ — ‍zwj — ́combining"
      [%{content: out}] = WireEncoding.scrub_messages([%{content: exotic}])
      assert out == exotic
      refute out =~ "�"
    end

    test "empty and degenerate inputs are no-ops" do
      assert WireEncoding.scrub_messages([]) == []
      assert WireEncoding.scrub_messages([%{content: ""}]) == [%{content: ""}]
      assert WireEncoding.scrub_messages(nil) == nil
      assert WireEncoding.scrub_messages([%{content: nil}]) == [%{content: nil}]
    end

    test "base64 image payloads are left alone" do
      b64 = Base.encode64(<<0xDA, 0x00, 0xFF, 0x01>>)
      messages = [%{role: "user", content: [%{"type" => "image", "data" => b64}]}]
      assert WireEncoding.scrub_messages(messages) === messages
    end
  end

  describe "scrubbing semantics" do
    test "bad bytes become U+FFFD — replaced, not dropped" do
      [%{content: out}] = WireEncoding.scrub_messages([%{content: "a" <> @bad <> "b"}])
      assert out == "a�b"
    end

    test "a bisected multi-byte codepoint is repaired, and the rest survives" do
      <<head::binary-size(2), _::binary>> = "🙈"
      [%{content: out}] = WireEncoding.scrub_messages([%{content: "tail " <> head}])
      assert String.valid?(out)
      assert out =~ "tail "
    end

    test "is idempotent — a retry or a fallback hop re-enters here" do
      once = WireEncoding.scrub_messages([%{content: "a" <> @bad}])
      assert WireEncoding.scrub_messages(once) === once
    end
  end

  # ── Attribution: the failure must stop being charged to the model ───────

  describe "failure attribution" do
    # The verbatim string the registry's rescue produces from the encode raise.
    @encode_failure "Provider error: invalid byte 0xDA in <<47, 116, 109, 112>>"

    test "the encoding failure classifies as :harness_error, not :unknown" do
      assert ErrorCatalog.classify(@encode_failure) == :harness_error
    end

    test "it is attributed to OSA, not the provider" do
      assert ErrorCatalog.fault_owner(@encode_failure) == :osa
    end

    test "the other rescue wrappers are the same category, not one instance" do
      for reason <- [
            "Provider error: no function clause matching in Messages.binary/2",
            "Provider Elixir.OptimalSystemAgent.Providers.Anthropic chat_stream raised: " <>
              "cannot convert the given list to a string",
            "Compat provider openrouter streaming raised: %KeyError{key: :model}"
          ] do
        assert ErrorCatalog.fault_owner(reason) == :osa, "missed: #{reason}"
      end
    end

    test "history corruption and bad request shapes are OSA's fault too" do
      for category <- [:harness_error, :request_shape, :tool_use_mismatch, :duplicate_tool_use] do
        assert ErrorCatalog.harness_fault?(category)
      end
    end

    # The guard against over-claiming: a real provider outage must still be
    # charged to the provider, or the fix trades one lie for its mirror image.
    test "genuine provider failures stay attributed to the provider" do
      for reason <- [
            {:rate_limited, 30},
            {:http_error, 529, "overloaded_error"},
            {:http_error, 500, "internal server error"},
            "Anthropic returned 401: invalid x-api-key",
            "request timed out"
          ] do
        assert ErrorCatalog.fault_owner(reason) == :provider, "misattributed: #{inspect(reason)}"
      end
    end

    # A raise whose text still carries a real provider diagnosis keeps the
    # precise category — the harness check runs after every specific branch.
    test "a rescue wrapping a recognisable provider message keeps its category" do
      assert ErrorCatalog.classify("Provider error: ANTHROPIC_API_KEY not configured") ==
               :missing_api_key
    end

    test "every category still yields a user message" do
      for category <- ErrorCatalog.categories() do
        assert is_binary(ErrorCatalog.user_message("synthetic #{category}"))
      end

      msg = ErrorCatalog.user_message(@encode_failure)
      assert msg =~ "bug in OSA"
      assert msg =~ "switching models will not help"
    end
  end
end
