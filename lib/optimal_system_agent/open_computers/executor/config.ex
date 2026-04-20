defmodule OptimalSystemAgent.OpenComputers.Executor.Config do
  @moduledoc """
  Configuration for the exec RPC executor.

  Reads `~/.osa/open_computers.json` if present. Falls back to safe defaults.

  ## JSON format

      {
        "exec": {
          "allowed": [],
          "max_concurrent": 8,
          "max_timeout_ms": 300000
        }
      }

  `"allowed": []` (or absent) means all commands are permitted.
  Set to a non-empty list to restrict to specific command names.
  """

  @default_max_concurrent 8
  @default_max_timeout_ms 300_000

  @doc """
  Return the allowed-commands configuration.

  Returns `:all` if no restriction, or `{:list, [String.t()]}` if restricted.
  An empty list in config means `:all`.
  """
  @spec allowed_commands() :: :all | {:list, [String.t()]}
  def allowed_commands do
    case read_exec_config() do
      %{"allowed" => [_ | _] = list} ->
        {:list, Enum.map(list, &to_string/1)}

      _ ->
        :all
    end
  end

  @doc "Maximum concurrent exec jobs."
  @spec max_concurrent() :: pos_integer()
  def max_concurrent do
    case read_exec_config() do
      %{"max_concurrent" => n} when is_integer(n) and n > 0 -> n
      _ -> @default_max_concurrent
    end
  end

  @doc "Hard cap on timeout_ms — jobs requesting more are capped."
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms do
    case read_exec_config() do
      %{"max_timeout_ms" => n} when is_integer(n) and n > 0 -> n
      _ -> @default_max_timeout_ms
    end
  end

  @doc "Return true if `cmd` is allowed by configuration."
  @spec command_allowed?(String.t()) :: boolean()
  def command_allowed?(cmd) when is_binary(cmd) do
    case allowed_commands() do
      :all -> true
      {:list, allowed} -> Path.basename(cmd) in allowed or cmd in allowed
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp read_exec_config do
    config_dir =
      Application.get_env(:optimal_system_agent, :config_dir, "~/.osa")
      |> Path.expand()

    path = Path.join(config_dir, "open_computers.json")

    with {:ok, content} <- File.read(path),
         {:ok, %{"exec" => exec}} <- Jason.decode(content) do
      exec
    else
      _ -> %{}
    end
  end
end
