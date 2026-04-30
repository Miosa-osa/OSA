defmodule OptimalSystemAgent.Agent.Memory.Taxonomy do
  @moduledoc """
  Alias module — delegates to MiosaMemory.Taxonomy.

  Preserved for backward compatibility with existing OSA callers.
  The implementation lives in the `miosa_memory` package.
  """

  # Re-export the struct type
  defdelegate new(content, opts \\ []), to: MiosaMemory.Taxonomy
  defdelegate categorize(content), to: MiosaMemory.Taxonomy
  defdelegate filter_by(entries, filters), to: MiosaMemory.Taxonomy
  defdelegate categories(), to: MiosaMemory.Taxonomy
  defdelegate scopes(), to: MiosaMemory.Taxonomy
  defdelegate touch(entry), to: MiosaMemory.Taxonomy
  defdelegate valid_category?(cat), to: MiosaMemory.Taxonomy
  defdelegate valid_scope?(scope), to: MiosaMemory.Taxonomy

  # Type alias: callers using Taxonomy.t() should use MiosaMemory.Taxonomy.t()
  @type t :: MiosaMemory.Taxonomy.t()
  @type category :: MiosaMemory.Taxonomy.category()
  @type scope :: MiosaMemory.Taxonomy.scope()
end
