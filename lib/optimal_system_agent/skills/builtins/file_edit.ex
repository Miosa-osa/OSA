defmodule OptimalSystemAgent.Skills.Builtins.FileEdit do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  # Copy the EXACT security constants from FileRead AND FileWrite
  @default_allowed_paths ["~", "/tmp"]
  @sensitive_paths [".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_dsa",
    ".gnupg/", ".aws/credentials", ".env", "/etc/shadow", "/etc/sudoers",
    "/etc/master.passwd", ".netrc", ".npmrc", ".pypirc"]
  @blocked_write_paths [".ssh/", ".gnupg/", "/etc/", "/boot/", "/usr/",
    "/bin/", "/sbin/", "/var/", ".aws/", ".env"]

  @impl true
  def name, do: "file_edit"

  @impl true
  def description, do: "Make surgical string replacements in a file. old_string must be unique in the file."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Absolute path to the file"},
        "old_string" => %{"type" => "string", "description" => "Exact text to find (must be unique in file)"},
        "new_string" => %{"type" => "string", "description" => "Text to replace it with"}
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def execute(%{"path" => path, "old_string" => old, "new_string" => new}) do
    expanded = Path.expand(path)

    cond do
      not read_allowed?(expanded) ->
        {:error, "Access denied: #{path} is outside allowed paths or is a sensitive file"}
      not write_allowed?(expanded) ->
        {:error, "Access denied: #{path} targets a protected location"}
      old == new ->
        {:error, "old_string and new_string are identical"}
      old == "" ->
        {:error, "old_string cannot be empty"}
      true ->
        do_edit(expanded, path, old, new)
    end
  end
  def execute(_), do: {:error, "Missing required parameters: path, old_string, new_string"}

  defp do_edit(expanded, display_path, old, new) do
    case File.read(expanded) do
      {:ok, content} ->
        occurrences = count_occurrences(content, old)
        cond do
          occurrences == 0 ->
            {:error, "old_string not found in #{display_path}"}
          occurrences > 1 ->
            {:error, "old_string found #{occurrences} times — must be unique. Add more surrounding context."}
          true ->
            new_content = String.replace(content, old, new, global: false)
            File.write!(expanded, new_content)
            {:ok, "Replaced in #{display_path}"}
        end
      {:error, :enoent} -> {:error, "File not found: #{display_path}"}
      {:error, reason} -> {:error, "Cannot read #{display_path}: #{reason}"}
    end
  end

  defp count_occurrences(content, pattern) do
    content |> String.split(pattern) |> length() |> Kernel.-(1)
  end

  # Security: copy exact patterns from FileRead and FileWrite
  defp read_allowed?(expanded_path) do
    sensitive = Enum.any?(@sensitive_paths, fn p -> String.contains?(expanded_path, p) end)
    if sensitive do
      false
    else
      check = if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"
      Enum.any?(allowed_read_paths(), fn a -> String.starts_with?(check, a) end)
    end
  end

  defp write_allowed?(expanded_path) do
    if dotfile_outside_osa?(expanded_path) do
      false
    else
      blocked = Enum.any?(@blocked_write_paths, fn p -> String.contains?(expanded_path, p) end)
      if blocked do
        false
      else
        check = if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"
        Enum.any?(allowed_write_paths(), fn a -> String.starts_with?(check, a) end)
      end
    end
  end

  defp allowed_read_paths do
    Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp allowed_write_paths do
    Application.get_env(:optimal_system_agent, :allowed_write_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp dotfile_outside_osa?(expanded_path) do
    home = Path.expand("~")
    osa = Path.expand("~/.osa") <> "/"
    case String.split_at(expanded_path, byte_size(home)) do
      {^home, "/" <> rest} ->
        first = rest |> String.split("/") |> List.first()
        String.starts_with?(first, ".") and not String.starts_with?(expanded_path, osa)
      _ -> false
    end
  end
end
