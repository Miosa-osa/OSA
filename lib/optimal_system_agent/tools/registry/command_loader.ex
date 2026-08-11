defmodule OptimalSystemAgent.Tools.Registry.CommandLoader do
  @moduledoc """
  Loads user-defined slash commands from `~/.osa/commands/*.md`
  (Claude-Code-style custom commands).

  Each Markdown file becomes a `/<name>` slash command. The file may start with
  optional YAML frontmatter (`name`, `description`); the Markdown body is used as
  the prompt template. When the user runs `/<name> some args`, the body is
  submitted to the agent as the prompt, with `$ARGUMENTS` / `{{args}}`
  substituted by the argument string.

  Modeled on `OptimalSystemAgent.Tools.Registry.SkillLoader` — same
  frontmatter/body split, same defensive parsing (one malformed file must never
  crash the caller).

  Example `~/.osa/commands/review.md`:

      ---
      name: review
      description: Review the current diff for bugs and style issues
      ---
      Review the staged git diff. Focus on: $ARGUMENTS

  Running `/review security` submits the body with `$ARGUMENTS` replaced by
  `security` as the turn's prompt.
  """

  require Logger

  alias OptimalSystemAgent.Skills.Frontmatter

  defp commands_dir do
    Application.get_env(:optimal_system_agent, :commands_dir, "~/.osa/commands")
  end

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Load all custom commands as a map `name => %{name, description, template, path}`.

  Returns `%{}` when the directory is absent or unreadable. Command names are
  lower-cased and stripped of any leading `/`.
  """
  @spec load_commands() :: %{optional(String.t()) => map()}
  def load_commands do
    dir = Path.expand(commands_dir())

    if File.dir?(dir) do
      Path.join(dir, "*.md")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        case parse_command_file(path) do
          {:ok, cmd} -> Map.put(acc, cmd.name, cmd)
          :error -> acc
        end
      end)
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("[command_loader] load_commands failed: #{Exception.message(e)}")
      %{}
  end

  @doc "List custom commands as `{name, description}` tuples, sorted by name."
  @spec list_with_descriptions() :: [{String.t(), String.t()}]
  def list_with_descriptions do
    load_commands()
    |> Enum.map(fn {name, cmd} -> {name, cmd.description} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Look up a single custom command by name (case-insensitive). Returns nil if absent."
  @spec get(String.t()) :: map() | nil
  def get(name) when is_binary(name) do
    key = name |> String.trim() |> String.trim_leading("/") |> String.downcase()
    Map.get(load_commands(), key)
  end

  def get(_), do: nil

  @doc """
  Expand a command's template, substituting the argument string for the
  `$ARGUMENTS` and `{{args}}` placeholders. If the template has no placeholder
  and args are given, they are appended on a new line so nothing is lost.
  """
  @spec expand(map(), String.t()) :: String.t()
  def expand(%{template: template}, args) when is_binary(template) and is_binary(args) do
    args = String.trim(args)

    has_placeholder? =
      String.contains?(template, "$ARGUMENTS") or String.contains?(template, "{{args}}") or
        String.contains?(template, "{{ args }}")

    expanded =
      template
      |> String.replace("$ARGUMENTS", args)
      |> String.replace("{{ args }}", args)
      |> String.replace("{{args}}", args)

    if has_placeholder? or args == "" do
      expanded
    else
      expanded <> "\n\n" <> args
    end
  end

  # ── Private: parsing ──────────────────────────────────────────────────

  defp parse_command_file(path) do
    content = File.read!(path)
    default_name = path |> Path.basename(".md") |> String.downcase()

    {meta, body} =
      case Frontmatter.parse(content) do
        {:ok, m, rest} -> {m, rest}
        {:error, _reason} -> {%{}, OptimalSystemAgent.Utils.Bom.strip(content)}
      end

    template = String.trim(body)

    name =
      (meta["name"] || default_name)
      |> to_string()
      |> String.trim()
      |> String.trim_leading("/")
      |> String.downcase()

    description =
      case meta["description"] do
        d when is_binary(d) and d != "" -> d
        _ -> derive_description(template)
      end

    if name == "" or template == "" do
      :error
    else
      {:ok, %{name: name, description: description, template: template, path: path}}
    end
  rescue
    # A single unreadable/malformed command file must never crash the loader.
    e ->
      Logger.warning("[command_loader] Skipping #{path}: #{Exception.message(e)}")
      :error
  end

  # First non-blank line of the body, with any leading Markdown heading markers
  # stripped, truncated for the completion menu.
  defp derive_description(template) do
    template
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> "Custom command"
      line -> line |> String.replace(~r/^#+\s*/, "") |> String.slice(0, 80)
    end
  end
end
