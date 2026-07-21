defmodule OptimalSystemAgent.Protocol.TUISchema do
  @moduledoc """
  Single source of truth for the wire contract between the Elixir HTTP API
  (`OptimalSystemAgent.Channels.HTTP.*`) and the Rust TUI client
  (`priv/rust/tui/src/client`).

  The Rust client used to hand-mirror these payload shapes in `types.rs`, which
  could silently drift from the Elixir routes that actually produce them. This
  module declares the core payloads **once**, in Elixir, and the
  `mix osa.gen.tui_types` task projects them into a generated Rust module
  (`priv/rust/tui/src/client/generated.rs`) of serde structs. `types.rs`
  re-exports the generated structs, so the covered payloads cannot drift.

  Coverage (issue #33): health, sessions, messages, orchestrate req/resp, runs,
  rewind, config errors. Payloads that codegen does not reach (rich onboarding,
  swarm, models, skills, survey, …) stay hand-written in `types.rs`.

  ## Adding / changing a payload

  1. Edit `types/0` below (the protocol declaration).
  2. Run `mix osa.gen.tui_types` to regenerate `generated.rs`.
  3. `cargo build` the TUI.

  A test (`test/optimal_system_agent/protocol/tui_schema_test.exs`) and
  `mix osa.gen.tui_types --check` fail if `generated.rs` is out of date.

  ## Type DSL

  Field types are Elixir terms mapped to Rust:

      :string                 -> String
      :bool                   -> bool
      :i32 :i64 :u64 :f64     -> i32 / i64 / u64 / f64
      :json                   -> serde_json::Value
      {:option, t}            -> Option<t>
      {:vec, t}               -> Vec<t>
      {:map, k, v}            -> HashMap<k, v>
      {:struct, "Name"}       -> Name   (reference to another generated struct)

  Field options: `default: true` (serde `default`), `skip_none: true`
  (serde `skip_serializing_if = "Option::is_none"`, request bodies only),
  `rename: "type"` (serde `rename`), `doc: "..."` (a `///` comment).
  """

  @relative_output_path "priv/rust/tui/src/client/generated.rs"

  @doc "Absolute path to the generated Rust file (rooted at the app dir)."
  @spec output_path() :: String.t()
  def output_path, do: Path.join(File.cwd!(), @relative_output_path)

  @doc "Path of the generated Rust file relative to the app root."
  @spec relative_output_path() :: String.t()
  def relative_output_path, do: @relative_output_path

  # ── Protocol declaration ─────────────────────────────────────────────
  #
  # Order here is the order emitted into generated.rs (deterministic output).

  @doc """
  The protocol: the list of payload type definitions that are codegen'd.

  Each entry is a map with `:name`, `:derive` (`:serialize` | `:deserialize`),
  optional `:section`/`:doc`, and `:fields`.
  """
  @spec types() :: [map()]
  def types do
    [
      # === Health (GET /health) ===
      %{
        name: "HealthResponse",
        derive: :deserialize,
        section: "Health — GET /health",
        fields: [
          f("status", :string),
          f("version", :string),
          f("uptime_seconds", :i64, default: true),
          f("provider", :string),
          f("model", :string),
          f("context_window", {:option, :u64}, default: true),
          f("effort", {:option, :string},
            default: true,
            doc:
              "Current reasoning effort: \"fast\" | \"medium\" | \"high\" | \"xhigh\" | \"ultra\".\n`Option` + `default` keep older backends (which omit it) decodable."
          ),
          f("billing", {:option, {:struct, "HealthBilling"}},
            default: true,
            doc:
              "Spend/limit snapshot from the backend Budget. `null` when Budget is\nunavailable; individual limits are `null` when uncapped."
          ),
          f("update", {:option, {:struct, "HealthUpdate"}},
            default: true,
            doc:
              "Cached \"update available\" signal. `available: false` on source/dev\nbuilds, when the checker hasn't run, or on failure. Drives the TUI's\none-time startup notice + status-bar chip; the user runs `/update`."
          )
        ]
      },
      %{
        name: "HealthUpdate",
        derive: :deserialize,
        doc:
          "Update-availability signal carried on `GET /health`. Understated, never\nauto-installs (Codex parity). `latest_version` is `null` when unknown or\nwhen already up to date.",
        fields: [
          f("available", :bool, default: true),
          f("current_version", :string, default: true),
          f("latest_version", {:option, :string}, default: true)
        ]
      },
      %{
        name: "HealthBilling",
        derive: :deserialize,
        doc: "Billing projection carried on `GET /health` (see tui-statusline-spec).",
        fields: [
          f("daily_spent_usd", :f64, default: true),
          f("daily_limit_usd", {:option, :f64}, default: true),
          f("monthly_spent_usd", :f64, default: true),
          f("monthly_limit_usd", {:option, :f64}, default: true),
          f("currency", :string, default: true),
          f("subscription", {:option, :string},
            default: true,
            doc:
              "Subscription/plan tier. Always `null` today (OSA has no plan concept),\nbut wired so a chip appears if a plan is ever set."
          ),
          f("daily_tokens", :u64,
            default: true,
            doc:
              "Tokens consumed today. Used to render a token-usage chip for providers\nthat don't price in USD (e.g. glm), where a dollar figure is meaningless."
          ),
          f("usd_pricing", :bool,
            default: true,
            doc:
              "Whether this provider's spend is denominated in USD. When false, the\nstatus line must never show a `$` figure — show token usage instead."
          )
        ]
      },

      # === Orchestrate (POST /api/v1/orchestrate) ===
      %{
        name: "ContextRef",
        derive: :serialize,
        doc:
          "A structured `@`-mention carried onto the turn (composer `mentions::Attachment`\nminus IMAGE, which already rides `images`). `type` is \"file\" or \"agent\".\nFor \"file\": `path` is set, `range` is an optional \"start\" or \"start-end\"\nline range (`#L10-20`). For \"agent\": `name` is set, `path`/`range` are omitted.",
        fields: [
          f("kind", :string, rename: "type", doc: ~s{"file" | "agent".}),
          f("path", {:option, :string}, skip_none: true),
          f("range", {:option, :string}, skip_none: true),
          f("name", {:option, :string}, skip_none: true)
        ]
      },
      %{
        name: "OrchestrateRequest",
        derive: :serialize,
        section: "Orchestrate — POST /api/v1/orchestrate",
        fields: [
          f("input", :string),
          f("session_id", {:option, :string}, skip_none: true),
          f("user_id", {:option, :string}, skip_none: true),
          f("workspace_id", {:option, :string}, skip_none: true),
          f("skip_plan", {:option, :bool}, skip_none: true),
          f("working_dir", {:option, :string}, skip_none: true),
          f("images", {:option, {:vec, :string}},
            skip_none: true,
            doc: "Attachments for vision-capable models: file paths or base64-encoded images."
          ),
          f("context_refs", {:option, {:vec, {:struct, "ContextRef"}}},
            skip_none: true,
            doc:
              "Non-image `@file` / `@agent` composer mentions, carried as structured\nrefs instead of only inline prompt text. Absent/empty is today's behavior\n(unchanged) — the backend resolves each ref into a context block appended\nto the prompt before the turn reaches the agent loop."
          )
        ]
      },
      %{
        name: "OrchestrateResponse",
        derive: :deserialize,
        doc: "202 Accepted — the full reply arrives over the SSE stream.",
        fields: [
          f("session_id", :string),
          f("status", :string)
        ]
      },

      # === Sessions ===
      %{
        name: "SessionMessage",
        derive: :deserialize,
        section: "Sessions",
        fields: [
          f("role", :string),
          f("content", :string),
          f("timestamp", {:option, :string}, default: true)
        ]
      },
      %{
        name: "SessionInfo",
        derive: :deserialize,
        doc: "A session summary or a full session (with messages) from GET /sessions/:id.",
        fields: [
          f("id", :string),
          f("created_at", :string),
          f("title", :string, default: true),
          f("message_count", :i32, default: true),
          f("messages", {:option, {:vec, {:struct, "SessionMessage"}}}, default: true),
          f("last_active", {:option, :string},
            default: true,
            doc: "Timestamp of the most recent turn (present on listings)."
          )
        ]
      },
      %{
        name: "SessionListResponse",
        derive: :deserialize,
        doc: "GET /api/v1/sessions — paginated session listing.",
        fields: [
          f("sessions", {:vec, {:struct, "SessionInfo"}}),
          f("count", :i32, default: true),
          f("page", :i32, default: true),
          f("per_page", :i32, default: true)
        ]
      },
      %{
        name: "SessionCreateResponse",
        derive: :deserialize,
        doc: "POST /api/v1/sessions — created or resumed session.",
        fields: [
          f("id", :string),
          f("status", {:option, :string},
            default: true,
            doc: ~s{"created" for a new session, "resumed" when the folder already had one.}
          ),
          f("working_dir", {:option, :string}, default: true),
          f("created_at", {:option, :string}, default: true),
          f("title", {:option, :string}, default: true)
        ]
      },
      %{
        name: "SessionMessagesResponse",
        derive: :deserialize,
        doc: "GET /api/v1/sessions/:id/messages.",
        fields: [
          f("messages", {:vec, {:struct, "SessionMessage"}}),
          f("count", :i32, default: true)
        ]
      },
      %{
        name: "ContextStats",
        derive: :deserialize,
        doc: "GET /api/v1/sessions/:id/context — token-usage breakdown.",
        fields: [
          f("system_tokens", :u64, default: true),
          f("conversation_tokens", :u64, default: true),
          f("tool_result_tokens", :u64, default: true),
          f("max_tokens", :u64, default: true),
          f("used_tokens", :u64, default: true)
        ]
      },
      %{
        name: "CompactResponse",
        derive: :deserialize,
        doc: "POST /api/v1/sessions/:id/compact — proactive compaction result.",
        fields: [
          f("status", :string, default: true),
          f("messages_before", :u64, default: true),
          f("messages_after", :u64, default: true),
          f("tokens_before", :u64, default: true),
          f("tokens_after", :u64, default: true)
        ]
      },
      %{
        name: "RecapResponse",
        derive: :deserialize,
        doc: "GET /api/v1/sessions/:id/recap — short LLM summary of the session.",
        fields: [
          f("session_id", :string, default: true),
          f("recap", :string, default: true)
        ]
      },

      # === Runs (agent run dashboard) ===
      %{
        name: "RunSummary",
        derive: :deserialize,
        section: "Runs — GET /runs",
        doc: "A single agent run projected from RunStore.",
        fields: [
          f("id", :string),
          f("role", {:option, :string}, default: true),
          f("status", :string),
          f("parent_session_id", {:option, :string}, default: true),
          f("started_at", {:option, :string}, default: true),
          f("completed_at", {:option, :string}, default: true),
          f("duration_ms", {:option, :i64}, default: true),
          f("tokens", :i64, default: true),
          f("tool_count", :i32, default: true),
          f("task_preview", :string, default: true)
        ]
      },
      %{
        name: "RunListResponse",
        derive: :deserialize,
        doc: "GET /runs — active + background runs, newest first.",
        fields: [
          f("runs", {:vec, {:struct, "RunSummary"}}),
          f("active", {:vec, {:struct, "RunSummary"}}, default: true),
          f("active_count", :i32, default: true),
          f("count", :i32, default: true)
        ]
      },
      %{
        name: "RunCancelResponse",
        derive: :deserialize,
        doc: "POST /runs/:id/cancel.",
        fields: [
          f("status", :string),
          f("run_id", :string)
        ]
      },

      # === Rewind checkpoints (/rewind) ===
      %{
        name: "RewindCheckpoint",
        derive: :deserialize,
        section: "Rewind — /rewind",
        doc: "A snapshot of conversation (and optionally code) taken before a user prompt.",
        fields: [
          f("id", :string),
          f("label", :string, default: true),
          f("created_at", {:option, :string}, default: true),
          f("iteration", :i64, default: true),
          f("message_count", :i64, default: true),
          f("has_code", :bool, default: true)
        ]
      },
      %{
        name: "RewindListResponse",
        derive: :deserialize,
        doc: "GET /api/v1/rewind/:session_id — recent checkpoints, newest first.",
        fields: [
          f("checkpoints", {:vec, {:struct, "RewindCheckpoint"}}),
          f("count", :i32, default: true)
        ]
      },
      %{
        name: "RewindRestoreRequest",
        derive: :serialize,
        doc: ~s{POST /api/v1/rewind/restore. scope in "code" | "conversation" | "both".},
        fields: [
          f("session_id", :string),
          f("checkpoint_id", :string),
          f("scope", :string)
        ]
      },
      %{
        name: "RewindRestoreResponse",
        derive: :deserialize,
        fields: [
          f("scope", :string, default: true),
          f("message_count", {:option, :i64}, default: true)
        ]
      },

      # === Error / Config (config revision routes return this shape) ===
      %{
        name: "ErrorResponse",
        derive: :deserialize,
        section: "Errors — shared error envelope (incl. /config not_implemented)",
        fields: [
          f("error", :string),
          f("code", {:option, :string}, default: true),
          f("details", {:option, :string}, default: true)
        ]
      }
    ]
  end

  @doc "Names of all generated structs, in emission order."
  @spec type_names() :: [String.t()]
  def type_names, do: Enum.map(types(), & &1.name)

  # ── Rust rendering ───────────────────────────────────────────────────

  @doc "Render the full contents of `generated.rs` as a String."
  @spec render() :: String.t()
  def render do
    defs = types()

    IO.iodata_to_binary([
      header(defs),
      "\n",
      defs |> Enum.map(&render_type/1) |> Enum.intersperse("\n")
    ])
  end

  @doc "True if the on-disk generated file matches `render/0`."
  @spec up_to_date?() :: boolean()
  def up_to_date? do
    case File.read(output_path()) do
      {:ok, contents} -> contents == render()
      _ -> false
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Build a field definition map with defaults.
  defp f(name, type, opts \\ []) do
    %{
      name: name,
      type: type,
      doc: Keyword.get(opts, :doc),
      default: Keyword.get(opts, :default, false),
      skip_none: Keyword.get(opts, :skip_none, false),
      rename: Keyword.get(opts, :rename)
    }
  end

  defp header(defs) do
    needs_serialize? = Enum.any?(defs, &(&1.derive == :serialize))
    needs_deserialize? = Enum.any?(defs, &(&1.derive == :deserialize))

    serde_import =
      cond do
        needs_serialize? and needs_deserialize? -> "use serde::{Deserialize, Serialize};\n"
        needs_serialize? -> "use serde::Serialize;\n"
        needs_deserialize? -> "use serde::Deserialize;\n"
        true -> ""
      end

    hashmap_import =
      if Enum.any?(defs, fn d -> Enum.any?(d.fields, &uses_map?(&1.type)) end) do
        "use std::collections::HashMap;\n"
      else
        ""
      end

    """
    // @generated by `mix osa.gen.tui_types` from
    // OptimalSystemAgent.Protocol.TUISchema — DO NOT EDIT BY HAND.
    //
    // The Elixir protocol is the single source of truth for these payload shapes.
    // Regenerate:        mix osa.gen.tui_types
    // Verify up-to-date: mix osa.gen.tui_types --check
    //
    // types.rs re-exports everything here, so these payloads cannot drift from
    // the Elixir HTTP API. Backend contract fields exist because the JSON schema
    // requires them, not because Rust reads every one — dead_code is expected.
    #![allow(dead_code)]

    #{serde_import}#{hashmap_import}
    """
  end

  defp render_type(def) do
    [
      render_section(def),
      render_doc(Map.get(def, :doc), ""),
      "#{derive_line(def.derive)}\n",
      "pub struct #{def.name} {\n",
      Enum.map(def.fields, &render_field/1),
      "}\n"
    ]
  end

  defp render_section(%{section: section}) when is_binary(section),
    do: "// === #{section} ===\n\n"

  defp render_section(_), do: []

  defp render_field(field) do
    [
      render_doc(field.doc, "    "),
      Enum.map(serde_attrs(field), &"    #{&1}\n"),
      "    pub #{field.name}: #{rust_type(field.type)},\n"
    ]
  end

  defp render_doc(nil, _indent), do: []

  # A `doc` may contain newlines for a multi-line `///` block; prefix EVERY line
  # with `<indent>/// ` so continuation lines stay valid doc comments rather than
  # bare (uncompilable) text in the struct body.
  defp render_doc(doc, indent) do
    doc
    |> String.split("\n")
    |> Enum.map_join(fn line -> "#{indent}/// #{line}\n" end)
  end

  defp derive_line(:serialize), do: "#[derive(Debug, Clone, Serialize)]"
  defp derive_line(:deserialize), do: "#[derive(Debug, Clone, Deserialize)]"

  # Serde attribute lines for a field, in a stable order.
  defp serde_attrs(field) do
    args =
      []
      |> maybe_attr(field.rename, fn r -> ~s(rename = "#{r}") end)
      |> maybe_attr(field.skip_none, fn _ -> ~s(skip_serializing_if = "Option::is_none") end)
      |> maybe_attr(field.default, fn _ -> "default" end)

    case args do
      [] -> []
      list -> ["#[serde(#{Enum.join(list, ", ")})]"]
    end
  end

  defp maybe_attr(acc, nil, _fun), do: acc
  defp maybe_attr(acc, false, _fun), do: acc
  defp maybe_attr(acc, value, fun), do: acc ++ [fun.(value)]

  # Elixir type term -> Rust type string.
  defp rust_type(:string), do: "String"
  defp rust_type(:bool), do: "bool"
  defp rust_type(:i32), do: "i32"
  defp rust_type(:i64), do: "i64"
  defp rust_type(:u64), do: "u64"
  defp rust_type(:f64), do: "f64"
  defp rust_type(:json), do: "serde_json::Value"
  defp rust_type({:option, t}), do: "Option<#{rust_type(t)}>"
  defp rust_type({:vec, t}), do: "Vec<#{rust_type(t)}>"
  defp rust_type({:map, k, v}), do: "HashMap<#{rust_type(k)}, #{rust_type(v)}>"
  defp rust_type({:struct, name}) when is_binary(name), do: name

  defp uses_map?({:map, _, _}), do: true
  defp uses_map?({:option, t}), do: uses_map?(t)
  defp uses_map?({:vec, t}), do: uses_map?(t)
  defp uses_map?(_), do: false
end
