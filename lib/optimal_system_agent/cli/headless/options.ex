defmodule OptimalSystemAgent.CLI.Headless.Options do
  @moduledoc """
  Command-line options of `osa run`, the headless agent.

  Parsing is pure (`parse/1` takes argv, returns a struct or an error string)
  so the whole flag surface is testable without booting OSA. Flag names follow
  Claude Code's `claude -p` where an equivalent exists, with Codex's `exec`
  spellings accepted as aliases; `docs/headless.md` has the full mapping.
  """

  @formats ~w(text json stream-json)
  @input_formats ~w(text stream-json)

  # Session ids are filenames (`$OSA_HOME/sessions/<id>.json`). The persistence
  # layer rewrites every other character to `_`, which would make two ids map
  # to one file and break a caller that checks for `<id>.json` (MIOSA does), so
  # an id with any other character is refused rather than silently renamed.
  @session_id_format ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/

  @permission_modes %{
    "ask" => :ask,
    "default" => :ask,
    "auto-edit" => :accept_edits,
    "accept-edits" => :accept_edits,
    "acceptEdits" => :accept_edits,
    "plan" => :plan,
    "overdrive" => :overdrive,
    "bypass" => :overdrive,
    "bypassPermissions" => :overdrive
  }

  @switches [
    format: :string,
    output_format: :string,
    input_format: :string,
    model: :string,
    provider: :string,
    overdrive: :boolean,
    dangerously_skip_permissions: :boolean,
    yolo: :boolean,
    permission_mode: :string,
    resume: :string,
    continue: :boolean,
    session_id: :string,
    cwd: :string,
    cd: :string,
    max_turns: :integer,
    max_budget: :float,
    max_budget_usd: :float,
    effort: :string,
    append_system_prompt: :string,
    append_system_prompt_file: :string,
    system_prompt: :string,
    system_prompt_file: :string,
    tools: :keep,
    allowed_tools: :keep,
    allowedTools: :keep,
    disallowed_tools: :keep,
    disallowedTools: :keep,
    mcp_config: :keep,
    strict_mcp_config: :boolean,
    settings: :string,
    add_dir: :keep,
    output_last_message: :string,
    verbose: :boolean,
    quiet: :boolean,
    ask_user: :boolean,
    no_onboarding: :boolean,
    print: :boolean,
    help: :boolean
  ]

  @aliases [
    f: :format,
    m: :model,
    r: :resume,
    c: :continue,
    C: :cd,
    o: :output_last_message,
    q: :quiet,
    p: :print,
    h: :help
  ]

  @type t :: %__MODULE__{
          prompt: String.t() | nil,
          format: String.t(),
          input_format: String.t(),
          model: String.t() | nil,
          provider: String.t() | nil,
          permission_mode: atom() | nil,
          resume: String.t() | nil,
          continue: boolean(),
          session_id: String.t() | nil,
          cwd: String.t() | nil,
          max_turns: pos_integer() | nil,
          max_budget_usd: float() | nil,
          effort: String.t() | nil,
          append_system_prompt: String.t() | nil,
          system_prompt: String.t() | nil,
          tools: [String.t()] | nil,
          allowed_rules: [String.t()],
          disallowed_rules: [String.t()],
          mcp_configs: [String.t()],
          strict_mcp_config: boolean(),
          settings: String.t() | nil,
          add_dirs: [String.t()],
          output_last_message: String.t() | nil,
          verbose: boolean(),
          quiet: boolean(),
          ask_user: boolean(),
          help: boolean()
        }

  defstruct prompt: nil,
            format: "text",
            input_format: "text",
            model: nil,
            provider: nil,
            permission_mode: nil,
            resume: nil,
            continue: false,
            session_id: nil,
            cwd: nil,
            max_turns: nil,
            max_budget_usd: nil,
            effort: nil,
            append_system_prompt: nil,
            system_prompt: nil,
            tools: nil,
            allowed_rules: [],
            disallowed_rules: [],
            mcp_configs: [],
            strict_mcp_config: false,
            settings: nil,
            add_dirs: [],
            output_last_message: nil,
            verbose: false,
            quiet: false,
            ask_user: false,
            help: false

  @doc "The session id shape `osa run` accepts for `--resume` and `--session-id`."
  @spec session_id_format() :: Regex.t()
  def session_id_format, do: @session_id_format

  @doc "Parse argv. `{:ok, options}` or `{:error, message}` for a usage error."
  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse(argv) when is_list(argv) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    with :ok <- reject_invalid(invalid),
         {:ok, opts} <- build(parsed, positional),
         :ok <- validate(opts) do
      {:ok, opts}
    end
  end

  defp reject_invalid([]), do: :ok

  defp reject_invalid([{flag, nil} | _]),
    do: {:error, "unknown option #{flag} (see osa run --help)"}

  defp reject_invalid([{flag, value} | _]),
    do: {:error, "invalid value #{inspect(value)} for #{flag} (see osa run --help)"}

  defp build(parsed, positional) do
    get = fn key -> Keyword.get(parsed, key) end
    all = fn keys -> Enum.flat_map(keys, &Keyword.get_values(parsed, &1)) end

    overdrive? =
      get.(:overdrive) == true or get.(:dangerously_skip_permissions) == true or
        get.(:yolo) == true

    with {:ok, mode} <- permission_mode(get.(:permission_mode), overdrive?),
         {:ok, append} <-
           text_or_file(
             get.(:append_system_prompt),
             get.(:append_system_prompt_file),
             "--append-system-prompt"
           ),
         {:ok, system} <-
           text_or_file(get.(:system_prompt), get.(:system_prompt_file), "--system-prompt") do
      prompt =
        case positional do
          [] -> nil
          words -> Enum.join(words, " ")
        end

      {:ok,
       %__MODULE__{
         prompt: prompt,
         format: get.(:format) || get.(:output_format) || "text",
         input_format: get.(:input_format) || "text",
         model: blank_to_nil(get.(:model)),
         provider: blank_to_nil(get.(:provider)),
         permission_mode: mode,
         resume: get.(:resume),
         continue: get.(:continue) == true,
         session_id: get.(:session_id),
         cwd: get.(:cwd) || get.(:cd),
         max_turns: get.(:max_turns),
         max_budget_usd: get.(:max_budget) || get.(:max_budget_usd),
         effort: get.(:effort),
         append_system_prompt: append,
         system_prompt: system,
         tools: tool_list(all.([:tools])),
         allowed_rules: rule_list(all.([:allowed_tools, :allowedTools])),
         disallowed_rules: rule_list(all.([:disallowed_tools, :disallowedTools])),
         mcp_configs: all.([:mcp_config]),
         strict_mcp_config: get.(:strict_mcp_config) == true,
         settings: get.(:settings),
         add_dirs: all.([:add_dir]),
         output_last_message: get.(:output_last_message),
         verbose: get.(:verbose) == true,
         quiet: get.(:quiet) == true,
         ask_user: get.(:ask_user) == true,
         help: get.(:help) == true
       }}
    end
  end

  defp permission_mode(nil, true), do: {:ok, :overdrive}
  defp permission_mode(nil, false), do: {:ok, nil}

  defp permission_mode(raw, overdrive?) do
    case Map.fetch(@permission_modes, raw) do
      {:ok, :overdrive} ->
        {:ok, :overdrive}

      {:ok, _mode} when overdrive? ->
        {:error, "--permission-mode #{raw} conflicts with --overdrive"}

      {:ok, mode} ->
        {:ok, mode}

      :error ->
        {:error,
         "unknown --permission-mode #{inspect(raw)} (ask, auto-edit, plan, overdrive; " <>
           "Claude Code's default, acceptEdits and bypassPermissions also work)"}
    end
  end

  defp text_or_file(nil, nil, _flag), do: {:ok, nil}
  defp text_or_file(text, nil, _flag), do: {:ok, text}

  defp text_or_file(nil, path, flag) do
    case File.read(Path.expand(path)) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "#{flag}-file #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp text_or_file(_text, _path, flag),
    do: {:error, "#{flag} and #{flag}-file cannot both be given"}

  # `--tools a,b` / `--tools "a b"`, repeatable. Claude Code tool names are
  # accepted (`Bash` is `shell_execute`, see `Permissions`).
  defp tool_list([]), do: nil

  defp tool_list(values) do
    values
    |> Enum.flat_map(&String.split(&1, ~r/[\s,]+/, trim: true))
    |> Enum.map(&OptimalSystemAgent.Permissions.canonical_tool_name/1)
    |> Enum.uniq()
  end

  # Permission rules: `shell_execute(git:*)`, `Bash(npm test)`, `file_read`.
  # Commas split rules, but not inside a rule's parentheses.
  defp rule_list(values) do
    values
    |> Enum.flat_map(&split_rules/1)
    |> Enum.uniq()
  end

  @doc false
  @spec split_rules(String.t()) :: [String.t()]
  def split_rules(value) do
    {rules, current, _depth} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        "(", {rules, cur, depth} -> {rules, cur <> "(", depth + 1}
        ")", {rules, cur, depth} -> {rules, cur <> ")", max(depth - 1, 0)}
        sep, {rules, cur, 0} when sep in [",", " ", "\n", "\t"] -> {[cur | rules], "", 0}
        ch, {rules, cur, depth} -> {rules, cur <> ch, depth}
      end)

    [current | rules]
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp validate(%__MODULE__{} = o) do
    cond do
      o.help ->
        :ok

      o.format not in @formats ->
        {:error, "unknown --format #{inspect(o.format)} (text, json, stream-json)"}

      o.input_format not in @input_formats ->
        {:error, "unknown --input-format #{inspect(o.input_format)} (text, stream-json)"}

      o.input_format == "stream-json" and o.format != "stream-json" ->
        {:error, "--input-format stream-json needs --format stream-json"}

      o.input_format == "stream-json" and o.prompt != nil ->
        {:error,
         "with --input-format stream-json, send the messages on stdin, not as an argument"}

      Enum.count([o.resume != nil, o.continue, o.session_id != nil], & &1) > 1 ->
        {:error, "--resume, --continue and --session-id are mutually exclusive"}

      o.resume != nil and not Regex.match?(@session_id_format, o.resume) ->
        {:error, "invalid --resume id #{inspect(o.resume)}: letters, digits, - and _ only"}

      o.session_id != nil and not Regex.match?(@session_id_format, o.session_id) ->
        {:error, "invalid --session-id #{inspect(o.session_id)}: letters, digits, - and _ only"}

      o.max_turns != nil and o.max_turns < 1 ->
        {:error, "--max-turns must be at least 1"}

      o.max_budget_usd != nil and o.max_budget_usd <= 0 ->
        {:error, "--max-budget must be greater than 0"}

      o.verbose and o.quiet ->
        {:error, "--verbose and --quiet cannot both be given"}

      true ->
        :ok
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end
end
