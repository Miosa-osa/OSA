defmodule OptimalSystemAgent.Security.SandboxArtifacts do
  @moduledoc """
  Pull PoC and screenshot artifacts out of a sandbox workspace.

  Copy operator-useful files
  (PoCs, screenshots, HAR, logs) to a destination the operator can
  reach. Cookie and auth persistence files stay in the sandbox. Do
  not save cookies to a reused cloud sandbox.

  No network. No payloads. `File` only.
  """

  alias OptimalSystemAgent.Agent.Safety.PathCanon

  @default_max_bytes 5_000_000
  @default_max_files 20
  @allowed_exts MapSet.new(~w(.png .jpg .txt .har .json .log .py))

  @type copied :: %{path: String.t(), bytes: non_neg_integer(), sha256: String.t()}
  @type blocked :: %{path: String.t(), error: String.t()}
  @type result :: %{copied: [copied()], blocked: [blocked()]}

  @doc """
  Copy `paths` from sandbox `root` into `:dest`.

  Options:

    * `:dest` (required) - destination directory, created if missing
    * `:max_bytes` - per-file cap, default 5_000_000
    * `:max_files` - successful-copy cap, default 20

  Returns `{:ok, %{copied: [...], blocked: [...]}}` so refused cookie
  files stay visible. Empty `paths` or missing `:dest` is an error.
  A missing file is blocked, not a whole-call error.
  """
  @spec pull(String.t(), [String.t()], keyword()) :: {:ok, result()} | {:error, String.t()}
  def pull(root, paths, opts \\ [])

  def pull(_root, paths, _opts) when not is_list(paths) or paths == [] do
    {:error, "paths is required"}
  end

  def pull(root, paths, opts) when is_binary(root) and is_list(opts) do
    dest = Keyword.get(opts, :dest)

    cond do
      not is_binary(dest) or dest == "" ->
        {:error, "dest is required"}

      root == "" ->
        {:error, "root is required"}

      true ->
        do_pull(root, paths, opts, dest)
    end
  end

  def pull(_, _, _), do: {:error, "root is required"}

  defp do_pull(root, paths, opts, dest) do
    root = PathCanon.canonicalize(root)
    dest = PathCanon.canonicalize(dest)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    max_files = Keyword.get(opts, :max_files, @default_max_files)

    File.mkdir_p!(dest)

    {copied, blocked} =
      paths
      |> Enum.reduce({[], []}, fn path, {copied, blocked} ->
        case pull_one(root, dest, path, max_bytes, max_files, length(copied)) do
          {:copied, item} -> {[item | copied], blocked}
          {:blocked, item} -> {copied, [item | blocked]}
        end
      end)

    {:ok, %{copied: Enum.reverse(copied), blocked: Enum.reverse(blocked)}}
  end

  defp pull_one(_root, _dest, path, _max_bytes, _max_files, _copied_n) when not is_binary(path) do
    {:blocked, %{path: inspect(path), error: "path must be a string"}}
  end

  defp pull_one(_root, _dest, "", _max_bytes, _max_files, _copied_n) do
    {:blocked, %{path: "", error: "path must be a string"}}
  end

  defp pull_one(root, dest, path, max_bytes, max_files, copied_n) do
    cond do
      copied_n >= max_files ->
        {:blocked, %{path: path, error: "max_files exceeded"}}

      refused?(path) ->
        {:blocked, %{path: path, error: "refused: cookie/auth persistence"}}

      true ->
        case resolve_under_root(root, path) do
          {:error, reason} ->
            {:blocked, %{path: path, error: reason}}

          {:ok, abs, rel} ->
            copy_allowed(path, abs, rel, dest, max_bytes)
        end
    end
  end

  defp copy_allowed(original, abs, rel, dest, max_bytes) do
    cond do
      refused?(rel) or refused?(abs) or refused?(Path.basename(abs)) ->
        {:blocked, %{path: original, error: "refused: cookie/auth persistence"}}

      not allowed_artifact?(rel) ->
        {:blocked, %{path: original, error: "not an allowed artifact"}}

      not File.regular?(abs) ->
        {:blocked, %{path: original, error: "file not found"}}

      true ->
        case File.stat(abs) do
          {:ok, %File.Stat{size: size}} when size > max_bytes ->
            {:blocked, %{path: original, error: "exceeds max_bytes"}}

          {:ok, %File.Stat{size: size}} ->
            dest_file = dest_join(dest, rel)

            if dest_file && under_root?(dest, dest_file) do
              File.mkdir_p!(Path.dirname(dest_file))

              case File.cp(abs, dest_file) do
                :ok ->
                  {:copied,
                   %{
                     path: dest_file,
                     bytes: size,
                     sha256: file_sha256(dest_file)
                   }}

                {:error, reason} ->
                  {:blocked, %{path: original, error: "copy failed: #{inspect(reason)}"}}
              end
            else
              {:blocked, %{path: original, error: "path escapes sandbox root"}}
            end

          {:error, _} ->
            {:blocked, %{path: original, error: "file not found"}}
        end
    end
  end

  defp resolve_under_root(root, path) do
    trimmed =
      path
      |> String.trim()
      |> String.replace("\\", "/")

    abs =
      if Path.type(trimmed) == :absolute do
        PathCanon.canonicalize(trimmed)
      else
        PathCanon.canonicalize(Path.expand(trimmed, root))
      end

    if under_root?(root, abs) do
      rel = relative_to_root(root, abs)
      {:ok, abs, rel}
    else
      {:error, "path escapes sandbox root"}
    end
  end

  defp relative_to_root(root, abs) do
    rel = Path.relative_to(abs, root)

    if rel == abs do
      Path.basename(abs)
    else
      rel
    end
  end

  defp dest_join(dest, rel) do
    dest = PathCanon.canonicalize(dest)
    joined = PathCanon.canonicalize(Path.expand(rel, dest))
    if under_root?(dest, joined), do: joined, else: nil
  end

  defp under_root?(root, path) do
    root = String.trim_trailing(root, "/")
    path == root or String.starts_with?(path, root <> "/")
  end

  defp refused?(path) when is_binary(path) do
    n = normalize_path(path)
    base = Path.basename(n)

    String.contains?(n, "cookie") or
      String.contains?(n, "storage_state") or
      String.contains?(n, "localstorage") or
      String.contains?(n, "local_storage") or
      base == "session.json" or
      auth_dir?(n)
  end

  defp refused?(_), do: true

  defp auth_dir?(n) do
    n == ".auth" or
      String.starts_with?(n, ".auth/") or
      String.contains?(n, "/.auth/") or
      String.ends_with?(n, "/.auth")
  end

  defp allowed_artifact?(rel) do
    ext = rel |> Path.extname() |> String.downcase()
    base = Path.basename(rel) |> String.downcase()

    MapSet.member?(@allowed_exts, ext) and
      (ext != ".py" or String.starts_with?(base, "poc_"))
  end

  defp normalize_path(path) do
    path
    |> String.downcase()
    |> String.replace("\\", "/")
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
