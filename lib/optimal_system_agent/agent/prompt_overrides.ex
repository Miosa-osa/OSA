defmodule OptimalSystemAgent.Agent.PromptOverrides do
  @moduledoc """
  Operator-set system prompt overrides, persisted PER MODEL.

  Set from the CLI with `/system`:

    * `:inject`  — the operator text is appended to OSA's built-in static base
                   (SYSTEM.md + tool section) as an "Operator instructions" block.
    * `:replace` — the operator text IS the system prompt. The built-in base is
                   dropped entirely for that model.

  Entries live in `~/.osa/system_prompts.json` (`OSA_HOME` honoured), keyed by
  the exact model id the session runs (`/model` output). The special key `"*"`
  applies to every model that has no entry of its own. An entry survives until
  it is cleared; `enabled: false` keeps the text around while switching it off.

  `Agent.Context.build/1` consults `apply/2` on every prompt assembly, so a
  change takes effect on the next turn — no restart, no `/clear`.

  Subagent `system_prompt_override`s (AGENT.md role prompts) are NOT touched:
  these overrides only apply where OSA would otherwise use `Soul.static_base`.
  """

  require Logger

  @all "*"
  @file_name "system_prompts.json"
  @modes [:inject, :replace]

  @type mode :: :inject | :replace
  @type entry :: %{
          mode: mode(),
          text: String.t(),
          enabled: boolean(),
          updated_at: String.t() | nil
        }

  @inject_header "## Operator instructions\n\n" <>
                   "The operator appended the following to your system prompt with " <>
                   "`/system inject`. It is authoritative and extends everything above.\n\n"

  @doc "The wildcard key that applies to every model without its own entry."
  @spec all_key() :: String.t()
  def all_key, do: @all

  @doc "Where overrides are persisted."
  @spec path() :: String.t()
  def path do
    Application.get_env(:optimal_system_agent, :prompt_overrides_path) ||
      Path.join(osa_home(), @file_name)
  end

  @doc "All saved overrides as `%{model => entry}`."
  @spec list() :: %{String.t() => entry()}
  def list, do: read()

  @doc "The raw entry saved under exactly `model` (no wildcard fallback), or nil."
  @spec get(String.t()) :: entry() | nil
  def get(model) when is_binary(model), do: Map.get(read(), model)

  @doc """
  The override that governs `model` right now: the model's own entry, else the
  `"*"` entry — and only when enabled. Returns `{key, entry}` so callers can
  say which one applied, or nil.
  """
  @spec effective(String.t() | nil) :: {String.t(), entry()} | nil
  def effective(model) do
    overrides = read()

    candidates =
      if is_binary(model) and model != "", do: [model, @all], else: [@all]

    Enum.find_value(candidates, fn key ->
      case Map.get(overrides, key) do
        %{enabled: true} = entry -> {key, entry}
        _ -> nil
      end
    end)
  end

  @doc "Save (or overwrite) the override for `model`. Enables it."
  @spec set(String.t(), mode(), String.t()) :: :ok | {:error, term()}
  def set(model, mode, text)
      when is_binary(model) and mode in @modes and is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:error, :empty_text}
    else
      read()
      |> Map.put(model, %{mode: mode, text: text, enabled: true, updated_at: now()})
      |> write()
    end
  end

  @doc "Switch an existing override on/off without deleting its text."
  @spec enable(String.t(), boolean()) :: :ok | {:error, :not_found | term()}
  def enable(model, enabled?) when is_binary(model) and is_boolean(enabled?) do
    overrides = read()

    case Map.get(overrides, model) do
      nil ->
        {:error, :not_found}

      entry ->
        overrides
        |> Map.put(model, %{entry | enabled: enabled?, updated_at: now()})
        |> write()
    end
  end

  @doc "Delete the override for `model`. Succeeds even when nothing was saved."
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(model) when is_binary(model) do
    read() |> Map.delete(model) |> write()
  end

  @doc """
  Apply the effective override for `model` to the built-in static base.

  Returns `{prompt, applied}` where `applied` is `:none`, or `{key, mode}` for
  the entry that was used.
  """
  @spec apply(String.t(), String.t() | nil) ::
          {String.t(), :none | {String.t(), mode()}}
  def apply(static_base, model) when is_binary(static_base) do
    case effective(model) do
      nil ->
        {static_base, :none}

      {key, %{mode: :replace, text: text}} ->
        {text, {key, :replace}}

      {key, %{mode: :inject, text: text}} ->
        {static_base <> "\n\n" <> @inject_header <> text, {key, :inject}}
    end
  end

  # ── persistence ─────────────────────────────────────────────────────────

  defp read do
    case File.read(path()) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> Map.new(map, fn {k, v} -> {k, decode_entry(v)} end)
          _ -> %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("[PromptOverrides] cannot read #{path()}: #{inspect(reason)}")
        %{}
    end
  rescue
    _ -> %{}
  end

  defp write(overrides) when is_map(overrides) do
    file = path()

    json =
      overrides |> Map.new(fn {k, v} -> {k, encode_entry(v)} end) |> Jason.encode!(pretty: true)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, json <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_entry(%{} = v) do
    mode =
      case v["mode"] do
        "replace" -> :replace
        _ -> :inject
      end

    %{
      mode: mode,
      text: to_string(v["text"] || ""),
      enabled: v["enabled"] != false,
      updated_at: v["updated_at"]
    }
  end

  defp decode_entry(_), do: %{mode: :inject, text: "", enabled: false, updated_at: nil}

  defp encode_entry(%{mode: mode, text: text, enabled: enabled, updated_at: at}) do
    %{"mode" => Atom.to_string(mode), "text" => text, "enabled" => enabled, "updated_at" => at}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp osa_home, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")
end
