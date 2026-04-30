defmodule OptimalSystemAgent.Agent.Memory.Injector do
  @moduledoc """
  Alias module — delegates to MiosaMemory.Injector.

  Preserved for backward compatibility with existing OSA callers.
  The implementation lives in the `miosa_memory` package.
  """

  defdelegate inject_relevant(entries, context), to: MiosaMemory.Injector
  defdelegate format_for_prompt(entries), to: MiosaMemory.Injector

  @type injection_context :: MiosaMemory.Injector.injection_context()
end
