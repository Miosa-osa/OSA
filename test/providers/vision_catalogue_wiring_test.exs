defmodule OptimalSystemAgent.Providers.VisionCatalogueWiringTest do
  @moduledoc """
  OSA's own `vision:` flags must be the AUTHORITY for every provider whose
  model catalogue carries them — not just the four originally wired.

  Regression: `vision_catalogues/1` had no clause for `:xai` or `:zhipu`, so a
  vision-capable grok-4.6 / GLM resolved via `:unknown_default` (fail-open)
  instead of OSA's first-hand flag. Fail-open happens to allow a vision model,
  but it also wrongly allows a NON-vision model — the flag existed and was
  simply unreachable. (A module-name casing bug — XAIModels, not XaiModels —
  also silently defeated the first wiring.)
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ImageBudget

  test "grok vision flag is authoritative (osa_catalogue), not fail-open" do
    assert {true, :osa_catalogue} = ImageBudget.vision_decision(:xai, "grok-4.6")
    assert {true, :osa_catalogue} = ImageBudget.vision_decision(:xai, "grok-4.5")
  end

  test "vision_capable? stays true for grok (image is never dropped)" do
    assert ImageBudget.vision_capable?(:xai, "grok-4.6")
  end

  test "an unknown model still fails open (ignorance must not drop an image)" do
    assert {true, :unknown_default} = ImageBudget.vision_decision(:xai, "grok-does-not-exist-9")
  end
end
