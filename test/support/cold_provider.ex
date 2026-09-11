defmodule OptimalSystemAgent.Test.ColdProvider do
  @moduledoc """
  A `Providers.Behaviour` implementation that exists only so a test can UNLOAD it.

  Lives in `test/support` (which `elixirc_paths(:test)` compiles to disk) rather
  than inline in a `.exs` test file: an inline module is compiled in memory, so
  once purged it has no `.beam` to reload and the test can no longer tell
  "unloaded but loadable" from "deleted and gone".

  ## What it is for

  `Registry.register_provider/2` validated a candidate with
  `function_exported?/3` alone. That function answers `false` for a module that
  has not been loaded and does not load one, so a plugin registered before
  anything had called its code was rejected with "does not implement
  Providers.Behaviour" — about a module that does. Registering an *unloaded*
  module is the ordinary case at boot, which is why this is worth a regression
  test rather than a note.

  Implements exactly the three callbacks `Providers.Behaviour` requires, so it
  compiles clean; `chat_stream/3`, `available_models/0` and
  `native_tool_schemas?/0` are `@optional_callbacks`.
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  @impl true
  def chat(_messages, _opts), do: {:error, "ColdProvider is a test fixture"}

  @impl true
  def name, do: :cold_provider

  @impl true
  def default_model, do: "cold-model"
end
