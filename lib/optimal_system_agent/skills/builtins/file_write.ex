defmodule OptimalSystemAgent.Skills.Builtins.FileWrite do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "file_write"

  @impl true
  def description, do: "Write content to a file"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to write to"},
        "content" => %{"type" => "string", "description" => "Content to write"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}) do
    expanded = Path.expand(path)
    File.mkdir_p!(Path.dirname(expanded))

    case File.write(expanded, content) do
      :ok -> {:ok, "Written to #{expanded}"}
      {:error, reason} -> {:error, "Error writing file: #{reason}"}
    end
  end
end
