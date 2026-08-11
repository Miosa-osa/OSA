defmodule OptimalSystemAgent.Security.TypedText do
  @moduledoc """
  Masking for text that OSA types into a computer on the user's behalf.

  The `text` argument of a `computer_use` `type`/`key`-style action, a
  `browser` `type`/`fill` action, or a `clipboard_set` is exactly where a
  password goes. It has no distinguishing shape, so the pattern-based
  scrubber in `Agent.Trajectory` cannot catch it — the only safe treatment is
  to never let the literal value reach a display or a file in the first place.

  This module replaces such a value with its shape (`"<12 chars>"`) at every
  boundary that is not the executor itself. The real value continues to flow
  to the adapter that performs the keystrokes; it just stops flowing to the
  terminal, the TUI render map and `~/.osa/trajectories/`.

  ## Opt-in reveal

  Debugging a mis-typed string occasionally needs the literal text. That is
  gated behind an explicit switch which is OFF by default:

      config :optimal_system_agent, :reveal_typed_text, true
      # or
      OSA_REVEAL_TYPED_TEXT=1

  When enabled, typed text is printed and persisted in clear — including any
  password typed during that session. Nothing else in OSA turns this on.
  """

  # Actions whose text payload is treated as a credential by default.
  @sensitive_actions ~w(type type_text fill clipboard_set clipboard_write set_clipboard paste)

  # Field names, anywhere in a tool-argument map, that carry typed text.
  @sensitive_fields ~w(text value password passwd secret content)

  @doc """
  Actions whose `text` payload is masked.
  """
  @spec sensitive_actions() :: [String.t()]
  def sensitive_actions, do: @sensitive_actions

  @doc "True when `action` types characters into the machine."
  @spec sensitive_action?(term()) :: boolean()
  def sensitive_action?(action) when is_binary(action), do: action in @sensitive_actions

  def sensitive_action?(action) when is_atom(action) and not is_nil(action),
    do: Atom.to_string(action) in @sensitive_actions

  def sensitive_action?(_), do: false

  @doc """
  Replace a typed string with its shape.

      iex> OptimalSystemAgent.Security.TypedText.mask("hunter2")
      "<7 chars>"
  """
  @spec mask(term()) :: term()
  def mask(nil), do: nil
  def mask(""), do: "<empty>"

  def mask(text) when is_binary(text) do
    if reveal?() do
      text
    else
      "<#{safe_length(text)} chars>"
    end
  end

  def mask(other), do: mask(to_string(other))

  @doc """
  Mask `text` only when `action` is one that types characters.

  A `key` action ("ctrl+c") is not masked: it carries no secret and losing it
  makes the transcript unreadable.
  """
  @spec mask_for_action(term(), term()) :: term()
  def mask_for_action(action, text) do
    if sensitive_action?(action), do: mask(text), else: text
  end

  @doc """
  Mask the typed-text fields of a tool-argument map.

  Used at the persistence boundary, where only the decoded arguments are
  available. Keys are matched by name so a nested payload
  (`%{"input" => %{"text" => …}}`) is covered too.
  """
  @spec mask_args(term()) :: term()
  def mask_args(args) when is_map(args) and not is_struct(args) do
    action = args["action"] || args[:action]

    Map.new(args, fn {k, v} ->
      cond do
        sensitive_field?(k) and is_binary(v) and mask_field?(action) -> {k, mask(v)}
        true -> {k, mask_args(v)}
      end
    end)
  end

  def mask_args(list) when is_list(list), do: Enum.map(list, &mask_args/1)
  def mask_args(other), do: other

  @doc "True when typed text is being deliberately exposed."
  @spec reveal?() :: boolean()
  def reveal? do
    Application.get_env(:optimal_system_agent, :reveal_typed_text, false) == true or
      System.get_env("OSA_REVEAL_TYPED_TEXT") in ["1", "true", "TRUE"]
  end

  # ── Private ──

  # When the map carries an explicit action, only mask for typing actions.
  # When it does not (a nested payload, or a tool whose arguments are flat),
  # mask the named fields unconditionally — a bare `password` key is a secret
  # regardless of which tool produced it.
  defp mask_field?(nil), do: true
  defp mask_field?(action), do: sensitive_action?(action)

  defp sensitive_field?(k) when is_binary(k), do: String.downcase(k) in @sensitive_fields
  defp sensitive_field?(k) when is_atom(k), do: sensitive_field?(Atom.to_string(k))
  defp sensitive_field?(_), do: false

  # String.length/1 raises on invalid UTF-8; fall back to byte size.
  defp safe_length(text) do
    if String.valid?(text), do: String.length(text), else: byte_size(text)
  end
end
