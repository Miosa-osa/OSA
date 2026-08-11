defmodule OptimalSystemAgent.Skills.Frontmatter do
  @moduledoc """
  The ONE YAML-frontmatter parser for every authored markdown definition:
  `SKILL.md`, slash-command `.md` files and `AGENT.md`.

  Five near-identical copies of `String.split(content, "---", parts: 3)` used
  to live in `SkillLoader`, `UseSkill`, `CommandLoader`, `Agents.Registry` and
  `Skills.Validator`. They drifted, and none of them tolerated a UTF-8 BOM —
  an invisible three-byte prefix makes the head of that split `"﻿"` instead
  of `""`, so every one of them silently fell through to its no-frontmatter
  branch. The consequences were not cosmetic: a skill lost its `paths:` gate,
  a slash command lost its name, and a subagent lost `tools_blocked` while its
  raw frontmatter was handed to the model as a system prompt.

  This module is the single implementation. It strips the BOM first and
  reports *why* a parse failed, so callers can distinguish "this file declares
  no frontmatter" (fine) from "this file declares frontmatter that will not
  parse" (a security control may be missing — do not silently continue).
  """

  alias OptimalSystemAgent.Utils.Bom

  @type reason :: :missing | :unterminated | :invalid_yaml

  @doc """
  Split raw content into `{:ok, frontmatter_string, body}`.

  Errors:
    * `:missing`      — the file does not open with a `---` line at all.
    * `:unterminated` — it opens with `---` but never closes the block.
  """
  @spec split(binary()) :: {:ok, binary(), binary()} | {:error, reason()}
  def split(content) when is_binary(content) do
    content = Bom.strip(content)

    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        {:ok, frontmatter, body}

      _ ->
        if String.starts_with?(content, "---"),
          do: {:error, :unterminated},
          else: {:error, :missing}
    end
  end

  def split(_), do: {:error, :missing}

  @doc """
  Parse frontmatter into `{:ok, meta_map, body}`.

  Adds `:invalid_yaml` to `split/1`'s errors for a block that delimits
  correctly but is not a YAML mapping.
  """
  @spec parse(binary()) :: {:ok, map(), binary()} | {:error, reason()}
  def parse(content) do
    with {:ok, frontmatter, body} <- split(content) do
      case YamlElixir.read_from_string(frontmatter) do
        {:ok, meta} when is_map(meta) -> {:ok, meta, body}
        _ -> {:error, :invalid_yaml}
      end
    end
  end

  @doc """
  The instruction body only: BOM stripped and the frontmatter block removed.

  When there is no parseable frontmatter the whole (BOM-stripped) content is
  the body — that is the historical behaviour and is correct for a plain
  markdown file. Callers that must not leak raw YAML to a model should use
  `parse/1` and handle `{:error, :unterminated}` explicitly.
  """
  @spec body(binary()) :: binary()
  def body(content) when is_binary(content) do
    case split(content) do
      {:ok, _frontmatter, body} -> String.trim(body)
      {:error, _} -> content |> Bom.strip() |> String.trim()
    end
  end

  def body(_), do: ""

  @doc "Human-readable explanation of a `split/1` / `parse/1` error."
  @spec explain(reason()) :: String.t()
  def explain(:missing), do: "no YAML frontmatter (the file does not start with a `---` line)"

  def explain(:unterminated),
    do: "the YAML frontmatter opens with `---` but never closes with a second `---`"

  def explain(:invalid_yaml), do: "the YAML frontmatter is not a valid YAML mapping"
end
