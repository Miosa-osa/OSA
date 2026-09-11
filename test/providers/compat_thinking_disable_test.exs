defmodule OptimalSystemAgent.Providers.CompatThinkingDisableTest do
  @moduledoc """
  `thinking_disabled` must reach the wire ONLY where it was measured to work.

  `[OI]Compat` serves ~20 providers, and `thinking` is a foreign field on most
  of them — an unrecognized field there is a validation error, not an ignored
  one. So the lever is allowlisted, and the tests that matter are the ones
  proving it does NOT leak: a provider absent from the allowlist must see the
  exact bytes it saw before.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.OpenAICompat

  @surplus_url "https://api.surplusintelligence.ai/v1"
  # A model that genuinely reasons: the recovery exists for models that spend
  # their whole ceiling thinking.
  @model "deepseek-v4.1-flash"

  defp body(provider, opts) do
    OpenAICompat.build_stream_body(
      @model,
      [%{role: "user", content: "hi"}],
      Keyword.merge([provider: provider], opts),
      @surplus_url
    )
  end

  describe "thinking_disabled — the allowlisted path" do
    test "surplus carries the disable shape when the recovery asks for it" do
      assert %{thinking: %{"type" => "disabled"}} =
               body(:surplus, thinking_disabled: true)
    end

    test "the shape is the SAME dialect DeepSeekModels already emits for :disabled" do
      # One dialect, not two. If either side is ever re-spelled, this fails
      # rather than silently sending a shape the provider does not accept.
      # The effort argument is the STRING "off", not the atom `:disabled`:
      # `normalize_effort/1` dispatches on `to_string(effort)`, and only
      # "off"/"none" select the disabled branch - the atom stringifies to
      # "disabled", matches nothing, and falls through to "high" (ENABLED).
      # Passing the atom here asserts the opposite of what it reads like.
      from_catalog =
        OptimalSystemAgent.Providers.DeepSeekModels.thinking_params(
          "deepseek-v4-flash",
          "off"
        )

      assert %{"thinking" => expected} = from_catalog
      assert body(:surplus, thinking_disabled: true).thinking == expected
    end
  end

  describe "thinking_disabled — must NOT leak" do
    test "a provider that is not allowlisted gets no thinking field at all" do
      refute Map.has_key?(body(:groq, thinking_disabled: true), :thinking)
    end

    test "the flag being absent leaves the body untouched (the default path)" do
      # No recovery in flight: byte-for-byte what shipped before this lever.
      refute Map.has_key?(body(:surplus, []), :thinking)
    end

    test "an explicit false is the same as absent" do
      refute Map.has_key?(body(:surplus, thinking_disabled: false), :thinking)
    end

    test "an unknown provider is not assumed to accept it" do
      refute Map.has_key?(body(:some_unlisted_gateway, thinking_disabled: true), :thinking)
    end
  end
end
