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

  ## Prompt files — the no-command way

  A Markdown file in `~/.osa/prompts/` is picked up automatically:

      ~/.osa/prompts/<model>.md     for one model  (`/` and `:` in the tag become `_`)
      ~/.osa/prompts/default.md     for every model without its own file

  The file's mode is set by a `mode: inject` / `mode: replace` line anywhere
  in a leading `<!-- … -->` comment (default: inject). `/system file` creates
  the file with that header so the user only has to type the prompt.

  Precedence for a model: its JSON entry (an explicit `/system off` wins over
  a file) → its prompt file → the `"*"` JSON entry → `default.md`.

  `Agent.Context.build/1` consults `apply/2` on every prompt assembly, so a
  change takes effect on the next turn — no restart, no `/clear`.

  Subagent `system_prompt_override`s (AGENT.md role prompts) are NOT touched:
  these overrides only apply where OSA would otherwise use `Soul.static_base`.
  """

  require Logger

  @all "*"
  @file_name "system_prompts.json"
  @prompts_dir "prompts"
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
  The override that governs `model` right now. Returns `{key, entry}` so
  callers can say which one applied, or nil. `key` is the model, `"*"`, or
  the path of the prompt file that supplied it.

  Precedence: the model's JSON entry (disabled = explicitly off, stops here)
  → the model's prompt file → the `"*"` entry → `default.md`.
  """
  @spec effective(String.t() | nil) :: {String.t(), entry()} | nil
  def effective(model) do
    overrides = read()
    keys = if is_binary(model) and model != "", do: [model, @all], else: [@all]

    Enum.find_value(keys, fn key ->
      case Map.get(overrides, key) do
        %{enabled: true} = entry -> {key, entry}
        %{enabled: false} -> :off
        nil -> read_file(key)
      end
    end)
    |> case do
      :off -> nil
      other -> other
    end
  end

  # ── prompt files ──────────────────────────────────────────────────────

  @doc "Directory scanned for `<model>.md` / `default.md` prompt files."
  @spec prompts_dir() :: String.t()
  def prompts_dir do
    Application.get_env(:optimal_system_agent, :prompt_files_dir) ||
      Path.join(osa_home(), @prompts_dir)
  end

  @doc "The prompt file path for `model` (`\"*\"` → `default.md`)."
  @spec file_for(String.t()) :: String.t()
  def file_for(@all), do: Path.join(prompts_dir(), "default.md")

  def file_for(model) when is_binary(model) do
    Path.join(prompts_dir(), String.replace(model, ~r/[^A-Za-z0-9._-]/, "_") <> ".md")
  end

  @doc "Read and parse `model`'s prompt file, if present and non-empty."
  @spec read_file(String.t()) :: {String.t(), entry()} | nil
  def read_file(model) do
    path = file_for(model)

    case File.read(path) do
      {:ok, raw} ->
        {mode, text} = parse_file(raw)

        if text == "",
          do: nil,
          else: {path, %{mode: mode, text: text, enabled: true, updated_at: mtime(path)}}

      _ ->
        nil
    end
  end

  @doc """
  Create `model`'s prompt file with an explanatory header (unless it exists),
  seeded from the current override text if there is one. Returns the path.
  """
  @spec create_file(String.t(), mode()) :: {:ok, String.t()} | {:error, term()}
  def create_file(model, mode \\ :inject) when is_binary(model) and mode in @modes do
    path = file_for(model)

    if File.exists?(path) do
      {:ok, path}
    else
      seed =
        case get(model) do
          %{text: text} when text != "" -> text
          _ -> "Your instructions here.\n"
        end

      label = if model == @all, do: "every model", else: model

      header =
        "<!-- OSA system prompt for #{label}\n" <>
          "     mode: #{mode}\n" <>
          "     inject  = added on top of OSA's built-in prompt (tools keep working)\n" <>
          "     replace = this file becomes the ENTIRE system prompt\n" <>
          "     Saved automatically; takes effect on the next message. Delete the file to go back. -->\n\n"

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, header <> seed) do
        {:ok, path}
      end
    end
  end

  @doc "All prompt files present, as `%{model_or_\"*\" => {path, entry}}`."
  @spec list_files() :: %{String.t() => {String.t(), entry()}}
  def list_files do
    case File.ls(prompts_dir()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reduce(%{}, fn name, acc ->
          key = if name == "default.md", do: @all, else: String.trim_trailing(name, ".md")

          case read_file(key) do
            nil -> acc
            found -> Map.put(acc, key, found)
          end
        end)

      _ ->
        %{}
    end
  end

  # `mode:` inside a leading HTML comment sets the mode; the comment is
  # stripped so it never reaches the model.
  @doc false
  def parse_file(raw) do
    {comment, body} =
      case Regex.run(~r/\A\s*<!--(.*?)-->/s, raw, return: :index) do
        [{0, len} | _] -> {String.slice(raw, 0, len), String.slice(raw, len..-1//1)}
        _ -> {"", raw}
      end

    mode =
      case Regex.run(~r/mode:\s*(inject|replace)/i, comment) do
        [_, m] -> String.to_atom(String.downcase(m))
        _ -> :inject
      end

    {mode, String.trim(body)}
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: t}} -> t |> DateTime.from_unix!() |> DateTime.to_iso8601()
      _ -> nil
    end
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

  @doc """
  Delete the override for `model` — the JSON entry AND its prompt file.
  Succeeds even when nothing was saved.
  """
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(model) when is_binary(model) do
    _ = File.rm(file_for(model))
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
