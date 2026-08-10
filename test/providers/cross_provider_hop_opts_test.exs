defmodule OptimalSystemAgent.Providers.CrossProviderHopOptsTest do
  @moduledoc """
  A fallback hop to a DIFFERENT provider must not carry `opts[:model]`.

  `:model` is resolved for the provider the turn started on. Forwarding it
  across a hop asks e.g. Ollama for `claude-sonnet-5`, a tag its daemon has
  never heard of, so the hop fails for a reason unrelated to the original
  fault — and since a chain reports its LAST error, that impostor is the error
  the user sees. It is the mechanism that made an Anthropic history bug read as
  an Ollama JSON parse error, "unfixable by switching models".

  The head of the chain is the exception: it IS the provider `:model` was
  resolved for, so it must keep it.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.FallbackChain
  alias OptimalSystemAgent.Providers.Registry

  describe "cross_provider_opts/1" do
    test "drops :model and preserves every other opt" do
      opts = [model: "claude-sonnet-5", temperature: 0.2, provider: :anthropic, max_tokens: 4096]

      hopped = Registry.cross_provider_opts(opts)

      refute Keyword.has_key?(hopped, :model)
      assert Keyword.get(hopped, :temperature) == 0.2
      assert Keyword.get(hopped, :max_tokens) == 4096
      assert Keyword.get(hopped, :provider) == :anthropic
    end

    test "is a no-op when no model was pinned" do
      opts = [temperature: 0.2]
      assert Registry.cross_provider_opts(opts) == opts
    end

    test "is idempotent across repeated hops" do
      once = Registry.cross_provider_opts(model: "gpt-4o", temperature: 0.2)
      assert Registry.cross_provider_opts(once) == once
    end
  end

  describe "FallbackChain hop ordering" do
    # `chat_with_fallback/2` builds `[primary | fallbacks]` and threads an
    # `errors` accumulator that is empty only before the first attempt. That is
    # what distinguishes the head from a hop, so pin the mapping directly: if
    # the head ever stopped keeping `:model`, every turn would silently ignore
    # the user's chosen model.
    test "the head keeps :model and every later hop drops it" do
      opts = [model: "claude-sonnet-5", temperature: 0.2]

      assert head_opts = hop_opts(opts, [])
      assert Keyword.get(head_opts, :model) == "claude-sonnet-5"

      for errors <- [[{:anthropic, "boom"}], [{:anthropic, "boom"}, {:openai, "boom"}]] do
        refute Keyword.has_key?(hop_opts(opts, errors), :model),
               "hop after #{length(errors)} failure(s) must not carry the primary's model"
      end
    end

    # Reaches the private `hop_opts/2` the two chain walkers share. Testing the
    # public `chat_with_fallback/2` instead would require standing up real
    # provider HTTP, which is what the seam exists to avoid.
    defp hop_opts(opts, errors) do
      apply(FallbackChain, :hop_opts, [opts, errors])
    end
  end
end
