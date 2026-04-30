defmodule OptimalSystemAgent.Tools.Builtins.Download.Prompt do
  @moduledoc """
  Dynamic prompt for `download`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Download a file from a URL to a local path.

    Usage:
    - `url` must use the https:// scheme (http:// is only allowed for localhost).
    - `path` is the local destination. Relative paths resolve to ~/.osa/workspace/.
    - Requests to private/internal IP addresses are blocked (SSRF protection).
    - Maximum download size: 50 MB.
    """
  end
end
