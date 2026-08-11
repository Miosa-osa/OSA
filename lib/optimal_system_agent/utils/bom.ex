defmodule OptimalSystemAgent.Utils.Bom do
  @moduledoc """
  Byte-order-mark stripping for text OSA parses.

  A UTF-8 BOM (`U+FEFF`, bytes `EF BB BF`) is invisible in every editor and is
  written by default by several Windows editors and by PowerShell's
  `Out-File`/`>` redirection. None of the parsers OSA depends on tolerate it:

    * `Jason.decode/1` fails — the BOM is not JSON whitespace.
    * `:tomerl.parse/1` fails — its lexer has no BOM rule.
    * every `String.split(content, "---", parts: 3)` frontmatter split stops
      matching `["", frontmatter, body]`, because the head is `"﻿"`.
    * `String.trim_leading/1` does NOT remove it — `U+FEFF` is Unicode category
      `Cf` (format), not whitespace.

  So the BOM must be removed explicitly, at the read boundary, before anything
  looks at the content.
  """

  @bom "﻿"

  @doc """
  Remove a leading UTF-8 BOM, if present. Any other binary is returned as-is.

  Only ONE leading BOM is stripped: a `U+FEFF` later in the file is real
  content (a zero-width no-break space), not an encoding marker.
  """
  @spec strip(binary()) :: binary()
  def strip(@bom <> rest), do: rest
  def strip(content) when is_binary(content), do: content
  def strip(other), do: other

  @doc "True when `content` starts with a UTF-8 BOM."
  @spec present?(binary()) :: boolean()
  def present?(@bom <> _), do: true
  def present?(_), do: false
end
