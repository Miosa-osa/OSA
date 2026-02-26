defmodule OptimalSystemAgent.Skills.Builtins.ShellExecute do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @blocked_commands ~w(rm sudo dd mkfs fdisk)

  @impl true
  def name, do: "shell_execute"

  @impl true
  def description, do: "Execute a shell command safely"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "Shell command to execute"}
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command}) do
    first_word = command |> String.split() |> List.first() |> to_string()

    if first_word in @blocked_commands do
      {:error, "Blocked: #{first_word} is not allowed for safety"}
    else
      case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:error, "Exited #{code}:\n#{output}"}
      end
    end
  end
end
