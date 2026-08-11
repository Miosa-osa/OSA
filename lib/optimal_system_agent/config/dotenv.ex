defmodule OptimalSystemAgent.Config.Dotenv do
  @moduledoc """
  The one parser for `.env` files on the credential path.

  ## Why this exists as a module rather than four copies of a `String.split`

  There were four: `Application.load_dotenv/0`, `Onboarding.parse_env_file/1`,
  `Onboarding.env_has_provider?/1` and `CLI.Setup.upsert_env/2`. Each trimmed
  a line and split on `=`. All four therefore shared one bug, and fixing it in
  one of them would have left the others reading the same file differently —
  which on this path means one surface reporting "no key configured" while
  another writes the key back out under a name the first cannot find.

  ## The bug: a byte-order mark is not whitespace

  `String.trim/1` removes whitespace, and U+FEFF is Unicode category **Cf**
  (format), not whitespace. A `.env` written by a Windows editor — and OSA
  ships a Windows build, so this is a supported way to produce the file —
  begins `EF BB BF`. The first line then parses as the key
  `"﻿ANTHROPIC_API_KEY"`, which is not `"ANTHROPIC_API_KEY"`, so the key
  is set under a name nothing reads and OSA reports that no key is configured
  while the user is looking at the key in the file.

  It is invisible in every editor and in most terminals, it only ever affects
  the FIRST entry, and the failure is reported as "no API key" rather than as
  a parse problem — which is about as hard to diagnose as configuration
  problems get.

  The repo already strips U+FEFF where untrusted text enters the prompt
  (`Agent.ContextDiscovery`, `Agent.Safety.PromptInjection`). It was simply
  never done on the path that reads credentials.

  ## What is deliberately NOT here

  No `export ` prefix handling, no multi-line values, no variable
  interpolation. This parser matches what OSA's own writers emit and what its
  boot loader has always accepted; widening it would change which files are
  considered valid, which is a behaviour change and not a bug fix.
  """

  # Everything zero-width or invisible that can precede a key name and make it
  # a different string than it looks like. A BOM is the one that occurs in
  # practice; the rest cost nothing to include and are the same class of
  # problem (a hand-pasted key from a web page can carry U+200B).
  @invisible ~r/[\x{FEFF}\x{200B}\x{200C}\x{200D}\x{200E}\x{200F}\x{2060}\x{00AD}]/u

  @doc """
  Remove a leading byte-order mark and any other invisible formatting
  codepoints from raw file content.
  """
  @spec strip_invisible(binary()) :: binary()
  def strip_invisible(content) when is_binary(content) do
    String.replace(content, @invisible, "")
  end

  def strip_invisible(other), do: other

  @doc """
  Parse `.env` content into an ordered `[{key, value}]` list.

  Blank lines and `#` comments are skipped. The **first** occurrence of a key
  wins, mirroring the boot loader's "only set a var when it is not already
  present" rule — so the two cannot disagree about which of two duplicate
  lines is live.
  """
  @spec parse(binary()) :: [{String.t(), String.t()}]
  def parse(content) when is_binary(content) do
    content
    |> strip_invisible()
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case parse_line(line) do
        {:ok, {k, v}} ->
          if List.keymember?(acc, k, 0), do: acc, else: acc ++ [{k, v}]

        :skip ->
          acc
      end
    end)
  end

  @doc """
  Parse a `.env` file. A missing or unreadable file yields `[]`.

  Callers that must distinguish "absent" from "unreadable" — because they
  REWRITE the file from what they read, and so would destroy its contents —
  must not use this. `CLI.Setup.read_env_file!/1` is the one that has to make
  that distinction and does.
  """
  @spec parse_file(Path.t()) :: [{String.t(), String.t()}]
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      _ -> []
    end
  end

  @doc """
  Parse a single line into `{:ok, {key, value}}` or `:skip`.

  Quotes are stripped from the value, matching what every previous copy of
  this loop did.
  """
  @spec parse_line(binary()) :: {:ok, {String.t(), String.t()}} | :skip
  def parse_line(line) when is_binary(line) do
    trimmed = line |> strip_invisible() |> String.trim()

    cond do
      trimmed == "" ->
        :skip

      String.starts_with?(trimmed, "#") ->
        :skip

      true ->
        case String.split(trimmed, "=", parts: 2) do
          [k, v] ->
            key = String.trim(k)

            if key == "" do
              :skip
            else
              {:ok, {key, v |> String.trim() |> String.trim("\"") |> String.trim("'")}}
            end

          _ ->
            :skip
        end
    end
  end
end
