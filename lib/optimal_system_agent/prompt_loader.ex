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

    Logger.info("[PromptLoader] Loaded #{loaded}/#{length(@known_keys)} prompts")
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
