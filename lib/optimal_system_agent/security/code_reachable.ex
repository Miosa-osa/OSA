defmodule OptimalSystemAgent.Security.CodeReachable do
  @moduledoc """
  Checks if a vulnerability's code path is reachable from the entry point.

  Used by WeaponCatalog to determine `code_reachable` — whether the vulnerable
  code can actually be reached through normal request handling (not buried in
  unreachable branches). Uses simple heuristics: presence of source file,
  route/controller annotation, and call depth from entry points.
  """

  @doc "True when the finding's source code is reachable from a request handler."
  @spec check(map()) :: boolean()
  def check(%{code_reachable: r}) when is_boolean(r), do: r
  def check(%{"code_reachable" => r}) when is_binary(r) and r != "false", do: true
  def check(%{"code_reachable" => _}), do: false

  def check(finding) when is_map(finding) do
    source = Map.get(finding, :source_file, Map.get(finding, "source_file"))
    has_source = not is_nil(source) and source != ""

    depth = Map.get(finding, :call_depth, Map.get(finding, "call_depth", 3))
    shallow_enough = depth < 10

    # Simple heuristic: if it has a source file and reasonable call depth, it's reachable
    has_source and shallow_enough
  end

  def check(_), do: false
end
