defmodule OptimalSystemAgent.SDK.Message do
  @moduledoc """
  Typed message structs for the SDK.

  9 message types covering the full agent conversation lifecycle:
  user, assistant, tool_use, tool_result, system, plan, error, progress, budget.

  All messages share a common base (type, timestamp, session_id) and carry
  type-specific payload fields.
  """

  @type message_type ::
          :user
          | :assistant
          | :tool_use
          | :tool_result
          | :system
          | :plan
          | :error
          | :progress
          | :budget

  @type t :: %__MODULE__{
          type: message_type(),
          content: String.t() | nil,
          session_id: String.t() | nil,
          timestamp: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:type]
  defstruct [
    :type,
    :content,
    :session_id,
    timestamp: nil,
    metadata: %{}
  ]

  # ── Constructors ─────────────────────────────────────────────────

  @doc "Create a user message."
  @spec user(String.t(), keyword()) :: t()
  def user(content, opts \\ []) do
    %__MODULE__{
      type: :user,
      content: content,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create an assistant response message."
  @spec assistant(String.t(), keyword()) :: t()
  def assistant(content, opts \\ []) do
    %__MODULE__{
      type: :assistant,
      content: content,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create a tool_use message (assistant requesting a tool call)."
  @spec tool_use(String.t(), String.t(), map(), keyword()) :: t()
  def tool_use(tool_call_id, name, arguments, opts \\ []) do
    %__MODULE__{
      type: :tool_use,
      content: nil,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata:
        Map.merge(Keyword.get(opts, :metadata, %{}), %{
          tool_call_id: tool_call_id,
          name: name,
          arguments: arguments
        })
    }
  end

  @doc "Create a tool_result message."
  @spec tool_result(String.t(), String.t(), keyword()) :: t()
  def tool_result(tool_call_id, content, opts \\ []) do
    %__MODULE__{
      type: :tool_result,
      content: content,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata:
        Map.merge(Keyword.get(opts, :metadata, %{}), %{
          tool_call_id: tool_call_id
        })
    }
  end

  @doc "Create a system message."
  @spec system(String.t(), keyword()) :: t()
  def system(content, opts \\ []) do
    %__MODULE__{
      type: :system,
      content: content,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create a plan message (plan mode output)."
  @spec plan(String.t(), map(), keyword()) :: t()
  def plan(content, signal, opts \\ []) do
    %__MODULE__{
      type: :plan,
      content: content,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata: Map.merge(Keyword.get(opts, :metadata, %{}), %{signal: signal})
    }
  end

  @doc "Create an error message."
  @spec error(String.t(), keyword()) :: t()
  def error(reason, opts \\ []) do
    %__MODULE__{
      type: :error,
      content: reason,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create a progress message (intermediate tool/swarm status)."
  @spec progress(String.t(), keyword()) :: t()
  def progress(content, opts \\ []) do
    %__MODULE__{
      type: :progress,
      content: content,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Create a budget message (token/cost tracking)."
  @spec budget(map(), keyword()) :: t()
  def budget(budget_info, opts \\ []) do
    %__MODULE__{
      type: :budget,
      content: nil,
      session_id: Keyword.get(opts, :session_id),
      timestamp: now(),
      metadata: Map.merge(Keyword.get(opts, :metadata, %{}), budget_info)
    }
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp now, do: DateTime.utc_now()
end
