defmodule OptimalSystemAgent.PromptLoader do
  @moduledoc """
  Loads prompt templates from disk and caches them in `:persistent_term`.

  Lookup order for each prompt key:
    1. `~/.osa/prompts/<key>.md`   (user override)
    2. `priv/prompts/<key>.md`     (bundled default)

  If neither file exists the key maps to `nil` — callers are expected to
  handle their own inline fallback.

  ## Public API

      load/0  — read all prompt files from disk into persistent_term (boot + reload)
      get/1   — fetch a cached prompt by atom key, returns String.t() | nil
      get/2   — fetch with a default fallback value
  """

  require Logger

  @prompts_dir "~/.osa/prompts"

  @known_keys ~w(
    classifier
    IDENTITY
    SOUL
    mode_behaviors
    genre_behaviors
    compactor_summary
    compactor_key_facts
    cortex_synthesis
    noise_filter
  )a

  # ── Public API ─────────────────────────────────────────────────

  @doc "Load all known prompt files into persistent_term."
  @spec load() :: :ok
  def load do
    user_dir = Path.expand(@prompts_dir)
    bundled_dir = Path.join(:code.priv_dir(:optimal_system_agent), "prompts")

    loaded =
      Enum.reduce(@known_keys, 0, fn key, count ->
        filename = "#{key}.md"

        content =
          read_file(Path.join(user_dir, filename)) ||
            read_file(Path.join(bundled_dir, filename))

        :persistent_term.put({__MODULE__, key}, content)
        if content, do: count + 1, else: count
      end)

    # Also load command prompt templates from priv/commands/
    cmd_count = load_command_prompts()

    Logger.info("[PromptLoader] Loaded #{loaded}/#{length(@known_keys)} prompts, #{cmd_count} command templates")
    :ok
  end

  @doc "Get a cached prompt by atom key. Returns nil when not found."
  @spec get(atom()) :: String.t() | nil
  def get(key) when is_atom(key) do
    :persistent_term.get({__MODULE__, key}, nil)
  end

  @doc "Get a cached prompt by atom key, returning `default` when not found."
  @spec get(atom(), term()) :: String.t() | term()
  def get(key, default) when is_atom(key) do
    :persistent_term.get({__MODULE__, key}, nil) || default
  end

  @doc "Get a command prompt template by category and name."
  @spec get_command(String.t(), String.t()) :: String.t() | nil
  def get_command(category, name) do
    :persistent_term.get({__MODULE__, :cmd, category, name}, nil)
  end

  @doc "List all loaded command prompt templates."
  @spec list_command_prompts() :: [{String.t(), String.t()}]
  def list_command_prompts do
    try do
      :persistent_term.get({__MODULE__, :cmd_index}, [])
    rescue
      ArgumentError -> []
    end
  end

  # ── Command Prompt Loader ─────────────────────────────────────

  defp load_command_prompts do
    priv_dir =
      case :code.priv_dir(:optimal_system_agent) do
        {:error, _} -> nil
        dir -> to_string(dir)
      end

    user_dir = Path.expand("~/.osa/commands")
    bundled_dir = if priv_dir, do: Path.join(priv_dir, "commands"), else: nil

    # Scan both directories for category/name.md files
    entries =
      scan_command_dir(user_dir) ++ scan_command_dir(bundled_dir)

    # Deduplicate (user overrides bundled)
    unique =
      entries
      |> Enum.uniq_by(fn {cat, name, _content} -> {cat, name} end)

    # Store each command prompt
    Enum.each(unique, fn {category, name, content} ->
      :persistent_term.put({__MODULE__, :cmd, category, name}, content)
    end)

    # Store an index for listing
    index = Enum.map(unique, fn {cat, name, _} -> {cat, name} end)
    :persistent_term.put({__MODULE__, :cmd_index}, index)

    length(unique)
  end

  defp scan_command_dir(nil), do: []

  defp scan_command_dir(dir) do
    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, entries} ->
          Enum.flat_map(entries, fn entry ->
            full_path = Path.join(dir, entry)

            cond do
              File.dir?(full_path) ->
                # Category directory — scan .md files inside
                case File.ls(full_path) do
                  {:ok, files} ->
                    files
                    |> Enum.filter(&String.ends_with?(&1, ".md"))
                    |> Enum.flat_map(fn file ->
                      case read_file(Path.join(full_path, file)) do
                        nil -> []
                        content -> [{entry, Path.basename(file, ".md"), content}]
                      end
                    end)

                  _ ->
                    []
                end

              String.ends_with?(entry, ".md") ->
                case read_file(full_path) do
                  nil -> []
                  content -> [{"root", Path.basename(entry, ".md"), content}]
                end

              true ->
                []
            end
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp read_file(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          trimmed = String.trim(content)
          if trimmed == "", do: nil, else: trimmed

        {:error, reason} ->
          Logger.warning("[PromptLoader] Failed to read #{path}: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  end
end
