defmodule OptimalSystemAgent.Skills.Builtins.FileRead do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "file_read"

  @impl true
  def description, do: "Read a file from the filesystem"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to read"}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(%{"path" => path}) do
    case File.read(Path.expand(path)) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Error reading file: #{reason}"}
    end
  end
end
