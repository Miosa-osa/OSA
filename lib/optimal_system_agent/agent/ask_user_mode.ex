defmodule OptimalSystemAgent.Agent.AskUserMode do
  @moduledoc """
  Whether `ask_user` is available to the model — **off by default, everywhere**.

  ## Why it is off

  `ask_user` blocks the tool-executing process for up to five minutes waiting
  for a human (see `Tools.Builtins.AskUser.Handler.execute/2`). In an attended
  TUI session that is a feature. In a long-running or unattended session it is
  a stall: the model asks a question nobody is there to answer, and the task
  stops until the timeout expires — repeatedly, since the model that wanted to
  ask once will want to ask again.

  A wrong assumption stated out loud is recoverable; a session that parked on a
  question at 02:00 and did nothing for the next six hours is not. So the tool
  is disabled unless the operator asks for it, in every context: TUI, headless
  `mix osa.run`, CLI, SDK, MCP.

  ## Resolution order

  Highest priority first:

    1. **Sticky per-session flag** — what `/ask-user on|off` set for THIS
       session id (ETS, this module).
    2. **`OSA_ASK_USER` env var** — `1/true/yes/on` enables. For a headless
       invocation that wants questions without a settings file.
    3. **Settings cascade key `"ask_user"`** — `true` enables. Read through
       `Settings.get_trusted/2`, so a `.osa/settings.json` in an UNTRUSTED
       workspace cannot turn it on. It is not an authorization key, but "a
       cloned repo can make an unattended agent park for five minutes at a
       time" is a denial-of-service the trust gate already exists to prevent,
       and gating costs nothing since the honest default is off anyway.
    4. **`false`.**

  Note the asymmetry: nothing here can turn the tool on *implicitly*. Every
  layer that enables it is an explicit operator act.

  ## Not persisted to disk

  Unlike `Agent.PermissionMode`, the sticky flag lives in ETS only. A daemon
  restart drops it, and both a resumed loop and the TUI's reconnect-time status
  query then resolve to the same value (the settings/env default), so the two
  cannot disagree — the same reasoning `Agent.CoordinatorMode` documents. An
  operator who wants the tool on across restarts sets `"ask_user": true` in
  `~/.osa/settings.json`, which is durable by construction.

  ## How "off" is enforced

  Two layers, deliberately:

    * **The tool is not in the array.** `Agent.Loop.init/1` pins the flag once
      at session start and filters `ask_user` out of `state.tools`;
      `Agent.Loop.ToolFilter.filter/2` re-applies the gate as its LAST pass so
      a mid-session `tool_search` widening cannot smuggle it back in. Under a
      native-schema provider a name absent from the array cannot be emitted at
      all, so this is the real gate — and because the default is off, it also
      makes the cached prefix *smaller* rather than larger.
    * **The handler refuses with instructions.** Non-native transports treat the
      array as advice, `use_tool` can name any registered tool, and a model can
      hallucinate a call. So `AskUser.Handler.execute/2` checks this module too
      and, when disabled, returns an `{:ok, _}` result telling the model to
      proceed on its best assumption and state that assumption. Not an error:
      an error would feed the doom-loop detector for something that is not a
      failure — the same reason a declined question resolves to `{:ok, _}`.

  ## Prompt-cache stability

  The flag is resolved ONCE per session (`Loop.init/1`) and pinned in loop
  state; every later request re-derives the same array, so the tool prefix the
  Anthropic cache keys on stays byte-identical within a session.

  `/ask-user on` mid-session is the one exception: it rewrites the array, which
  costs exactly one cache re-prime on the next request. That is a real price
  and the command says so in its confirmation rather than taking effect
  silently or pretending to be free.

  ## Known residual

  On a transport with NO native tool schemas, the model's tool documentation is
  the prose block in the system prompt, and that block is assembled once at boot
  into a `:persistent_term` cache shared by every session — it cannot vary per
  session without destroying the cache. So on those transports the ~180 tokens
  of `ask_user` prose stay in the prompt even while the tool is gated off. The
  handler refusal above is what makes a resulting call harmless. On native
  providers (Anthropic, the path where caching is measured) there is no residual
  at all: `PromptAssembler.render_native/2` already drops `ask_user`'s prose
  entirely, because its `prompt/1` is its `description/0`.
  """

  alias OptimalSystemAgent.Tools.Builtins.AskUser.Constants

  @table :osa_session_ask_user

  @env_var "OSA_ASK_USER"

  @settings_key "ask_user"

  @truthy ~w(1 true yes on enabled)

  # ── Sticky per-session flag ───────────────────────────────────────────

  @doc "Remember `on?` as the sticky ask_user flag for `session_id`."
  @spec put(String.t(), boolean()) :: :ok
  def put(session_id, on?) when is_binary(session_id) and is_boolean(on?) do
    ensure_table()
    :ets.insert(@table, {session_id, on?})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(_, _), do: :ok

  @doc "Forget the sticky flag for `session_id` (session end / reset to default)."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear(_), do: :ok

  @doc """
  The sticky flag explicitly set for `session_id`, or `nil` when none was set.

  `nil` is distinct from `false`: it means "no runtime choice was made", which
  is what lets the env/settings layers be consulted underneath.
  """
  @spec sticky(String.t() | nil) :: boolean() | nil
  def sticky(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, on?}] -> on?
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def sticky(_), do: nil

  # ── Resolution ────────────────────────────────────────────────────────

  @doc """
  Is `ask_user` enabled for `session_id`? See the moduledoc for the order.

  Never raises: any failure resolves to `false`, the safe direction — a session
  that cannot resolve the setting must not be one that parks on a question.
  """
  @spec enabled?(String.t() | nil) :: boolean()
  def enabled?(session_id \\ nil) do
    case sticky(session_id) do
      on? when is_boolean(on?) -> on?
      nil -> default_enabled?()
    end
  end

  @doc """
  The session-independent default — env var, then trusted settings, then false.

  Exposed so the TUI/status surfaces can say what a NEW session would get.
  """
  @spec default_enabled?() :: boolean()
  def default_enabled? do
    case System.get_env(@env_var) do
      v when is_binary(v) ->
        String.downcase(String.trim(v)) in @truthy

      _ ->
        truthy?(OptimalSystemAgent.Settings.get_trusted(@settings_key, false))
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp truthy?(true), do: true
  defp truthy?(v) when is_binary(v), do: String.downcase(String.trim(v)) in @truthy
  defp truthy?(_), do: false

  # ── Tool-array gating ─────────────────────────────────────────────────

  @doc """
  Drop `ask_user` from a tool list when `enabled?` is false; identity when true.

  Accepts the map-shaped tool specs used throughout the loop
  (`%{name: "ask_user", ...}`) and tolerates string keys.
  """
  @spec filter_tools(list(), boolean()) :: list()
  def filter_tools(tools, true) when is_list(tools), do: tools

  def filter_tools(tools, false) when is_list(tools) do
    Enum.reject(tools, &(tool_name(&1) == Constants.tool_name()))
  end

  def filter_tools(tools, _), do: tools

  defp tool_name(%{name: name}), do: to_string(name)
  defp tool_name(t) when is_map(t), do: to_string(t[:name] || t["name"] || "")
  defp tool_name(_), do: ""

  # ── Refusal text ──────────────────────────────────────────────────────

  @doc """
  What the model is told when it calls `ask_user` while it is disabled.

  An instruction, not an error: it names the constraint, forbids retrying, and
  says exactly what to do instead. The wording deliberately mirrors the
  declined/timed-out results in `AskUser.Handler` so the model already has a
  learned response to this shape.
  """
  @spec disabled_text() :: String.t()
  def disabled_text do
    "No answer — asking the user is disabled for this session, so this question " <>
      "reached nobody. Do not ask again. Continue with your best assumption and " <>
      "state that assumption explicitly in your next message, so it can be " <>
      "corrected later. (The operator can enable questions with `/ask-user on`.)"
  end

  # ── Table ─────────────────────────────────────────────────────────────

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
