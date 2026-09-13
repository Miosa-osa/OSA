defmodule OptimalSystemAgent.Tools.Builtins.Diff do
  @moduledoc """
  Show differences between two files or two text strings.

  ## Read guard

  `diff` renders arbitrary file contents into a tool observation, so it is a
  read primitive and carries exactly the read guard `file_read` does — via the
  shared `Agent.Safety.PathPolicy`, not a private copy. It used to keep its own
  blocklist, and that copy had drifted: it never learned about
  `~/.osa/subscriptions.json`, so `diff(file_a: "~/.osa/subscriptions.json",
  file_b: "/dev/null")` handed the operator's subscription bearer tokens
  straight to the model.

  Paths are canonicalised before the check, so a symlink cannot be used to
  reach a denied file either.
  """
  @behaviour MiosaTools.Behaviour

  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Tools.BoundedCmd

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "diff"

  @impl true
  def description, do: "Show differences between two files or between two text strings"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "file_a" => %{"type" => "string", "description" => "Path to the first file"},
        "file_b" => %{"type" => "string", "description" => "Path to the second file"},
        "text_a" => %{
          "type" => "string",
          "description" => "First text string (alternative to file_a)"
        },
        "text_b" => %{
          "type" => "string",
          "description" => "Second text string (alternative to file_b)"
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(params) do
    cond do
      params["file_a"] && params["file_b"] ->
        diff_files(params["file_a"], params["file_b"])

      params["text_a"] && params["text_b"] ->
        diff_texts(params["text_a"], params["text_b"])

      true ->
        {:error, "Provide either file_a and file_b, or text_a and text_b"}
    end
  end

  defp diff_files(path_a, path_b) when is_binary(path_a) and is_binary(path_b) do
    expanded_a = PathPolicy.canonical(path_a)
    expanded_b = PathPolicy.canonical(path_b)

    cond do
      not path_allowed?(expanded_a) ->
        {:error, "Access denied: #{path_a} is outside allowed paths or is a sensitive file"}

      not path_allowed?(expanded_b) ->
        {:error, "Access denied: #{path_b} is outside allowed paths or is a sensitive file"}

      not File.exists?(expanded_a) ->
        {:error, "File not found: #{path_a}"}

      not File.exists?(expanded_b) ->
        {:error, "File not found: #{path_b}"}

      true ->
        # `PathPolicy` and `File.exists?/1` both answer yes for a FIFO and for a
        # path on a stalled network mount, and `diff` blocks forever on either.
        # Same shape as the `rg` call that held a turn for 1h51m; bounded the
        # same way. `{:timeout, why}` is an ERROR, never an empty diff — "Files
        # are identical" for a comparison that never ran is the silent wrong
        # answer this whole exercise is about.
        case BoundedCmd.run("diff", ["-u", expanded_a, expanded_b],
               label: "diff",
               target: "#{path_a} vs #{path_b}"
             ) do
          {:ok, _output, 0} -> {:ok, "Files are identical"}
          {:ok, output, 1} -> {:ok, output}
          {:ok, output, code} -> {:error, "diff exited with code #{code}:\n#{output}"}
          {:timeout, why} -> {:error, why}
        end
    end
  end

  defp diff_files(_, _), do: {:error, "file_a and file_b must be strings"}

  defp path_allowed?(canonical_path) do
    not PathPolicy.sensitive?(canonical_path) and
      PathPolicy.within_roots?(canonical_path, PathPolicy.read_roots())
  end

  defp diff_texts(text_a, text_b) do
    tmp_dir = System.tmp_dir!()
    id = :rand.uniform(1_000_000)
    file_a = Path.join(tmp_dir, "osa_diff_a_#{id}.txt")
    file_b = Path.join(tmp_dir, "osa_diff_b_#{id}.txt")

    try do
      File.write!(file_a, text_a)
      File.write!(file_b, text_b)

      case BoundedCmd.run("diff", ["-u", file_a, file_b], label: "diff", target: "two temp files") do
        {:ok, _output, 0} -> {:ok, "Texts are identical"}
        {:ok, output, 1} -> {:ok, output}
        {:ok, output, code} -> {:error, "diff exited with code #{code}:\n#{output}"}
        {:timeout, why} -> {:error, why}
      end
    after
      File.rm(file_a)
      File.rm(file_b)
    end
  end
end
