defmodule OptimalSystemAgent.SDK.Config do
  @moduledoc """
  Configuration struct for embedded SDK mode.

  Consumers pass an `%SDK.Config{}` to `SDK.Supervisor` to boot the OSA runtime
  as a subset of the full application — no CLI, no channel adapters, no scheduler.

  ## Example

      config = %OptimalSystemAgent.SDK.Config{
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        max_budget_usd: 5.0,
        permission: :accept_edits,
        data_dir: "/tmp/osa_embedded"
      }

      children = [
        {OptimalSystemAgent.SDK.Supervisor, config}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """

  @type permission_mode :: :default | :accept_edits | :plan | :bypass | :deny_all

  @type t :: %__MODULE__{
          provider: atom(),
          model: String.t() | nil,
          max_budget_usd: float() | nil,
          permission: permission_mode(),
          tools: [module()],
          agents: [map()],
          hooks: [{atom(), String.t(), function(), keyword()}],
          data_dir: String.t(),
          http_port: integer() | nil
        }

  defstruct provider: :ollama,
            model: nil,
            max_budget_usd: nil,
            permission: :default,
            tools: [],
            agents: [],
            hooks: [],
            data_dir: "~/.osa",
            http_port: nil
end
