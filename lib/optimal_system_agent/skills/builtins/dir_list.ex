defmodule OptimalSystemAgent.Skills.Builtins.DirList do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @default_allowed_paths ["~", "/tmp"]
  @sensitive_paths [".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_dsa",
    ".gnupg/", ".aws/credentials", ".env", "/etc/shadow", "/etc/sudoers",
    "/etc/master.passwd", ".netrc", ".npmrc", ".pypirc"]

  @impl true
  def name, do: "dir_list"

  @impl true
  def description, do: "List files and directories with types and sizes"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Directory path to list (default: current directory)"}
      },
      "required" => []
    }
  end

  @impl true
  def execute(params) do
    path = Path.expand(params["path"] || ".")

    if not path_allowed?(path) do
      {:error, "Access denied: #{path} is outside allowed paths"}
    else
      case File.ls(path) do
        {:ok, entries} ->
          lines = entries
            |> Enum.sort()
            |> Enum.map(fn entry ->
              full = Path.join(path, entry)
              {type, size} = case File.stat(full) do
                {:ok, %{type: :directory}} -> {"dir", 0}
                {:ok, %{type: :regular, size: s}} -> {"file", s}
                {:ok, %{type: t, size: s}} -> {to_string(t), s}
                _ -> {"?", 0}
              end
              "#{type}\t#{format_size(size)}\t#{entry}"
            end)
          {:ok, Enum.join(lines, "\n")}
        {:error, :enoent} -> {:error, "Directory not found: #{path}"}
        {:error, reason} -> {:error, "Cannot list #{path}: #{reason}"}
      end
    end
  end

  defp format_size(0), do: "-"
  defp format_size(n) when n < 1_024, do: "#{n}B"
  defp format_size(n) when n < 1_048_576, do: "#{Float.round(n / 1_024, 1)}K"
  defp format_size(n), do: "#{Float.round(n / 1_048_576, 1)}M"

  defp path_allowed?(expanded_path) do
    sensitive = Enum.any?(@sensitive_paths, fn p -> String.contains?(expanded_path, p) end)
    if sensitive do
      false
    else
      check = if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"
      Enum.any?(allowed_paths(), fn a -> String.starts_with?(check, a) end)
    end
  end

  defp allowed_paths do
    Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end
end
