defmodule OptimalSystemAgent.Agent.Safety.Verdict do
  @moduledoc """
  The narrow interface type passed between the safety layers.

  A `Verdict` is the pure, side-effect-free result of classifying a single tool
  call. It carries the assessed `risk`, the `category` of threat that matched
  (if any), a human-readable `reason`, the `matched_rule` label, and the `tool`
  name that was classified.

  Separation of concerns:

    * `Rules` produces raw category matches (policy data).
    * `Classifier` folds those into a single highest-risk `Verdict` (pure policy).
    * `Guardian` consumes a `Verdict` and applies stateful enforcement (mechanism).

  The `Verdict` itself is inert — it never performs I/O and never mutates state.
  """

  @type risk :: :safe | :caution | :dangerous

  @type category ::
          :none
          | :privilege_escalation
          | :force_push
          | :prod_deploy
          | :secret_exfiltration
          | :mass_delete
          | :untrusted_network
          | :prompt_injection_driven

  @type t :: %__MODULE__{
          risk: risk(),
          category: category(),
          reason: String.t() | nil,
          matched_rule: String.t() | nil,
          tool: String.t() | nil
        }

  @enforce_keys [:risk]
  defstruct risk: :safe,
            category: :none,
            reason: nil,
            matched_rule: nil,
            tool: nil

  @doc "A benign verdict (nothing matched)."
  @spec safe(String.t() | nil) :: t()
  def safe(tool \\ nil), do: %__MODULE__{risk: :safe, category: :none, tool: tool}

  @doc "Numeric ordering used to pick the highest-risk verdict from a set."
  @spec severity(t() | risk()) :: 0 | 1 | 2
  def severity(%__MODULE__{risk: risk}), do: severity(risk)
  def severity(:safe), do: 0
  def severity(:caution), do: 1
  def severity(:dangerous), do: 2

  @doc "True when the verdict should be blocked outright."
  @spec dangerous?(t()) :: boolean()
  def dangerous?(%__MODULE__{risk: :dangerous}), do: true
  def dangerous?(%__MODULE__{}), do: false
end
