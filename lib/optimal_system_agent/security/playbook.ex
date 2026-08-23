defmodule OptimalSystemAgent.Security.Playbook do
  @moduledoc """
  Phased pentest playbooks (Tier 3 #10).

  Adapted from PentestAgent's playbook system. A playbook is an ordered
  sequence of phases an engagement moves through, each with entry criteria
  (what must be true to start the phase), exit criteria (what must be true to
  consider it complete), and guidance (the methodology to apply). The agent
  reports its current phase and advances when exit criteria are met.

  ## Built-in playbooks

  - `:web_app` — web application assessment (6 phases)
  - `:network` — internal network pentest (6 phases)
  - `:full_engagement` — combined recon + web + network + report (8 phases)

  ## State

  The active playbook + current phase + per-phase status is held per-session
  in an ETS-backed GenServer (`Security.PlaybookStore`) so it survives across
  turns. `advance/2` moves to the next phase when the agent declares exit
  criteria met; `current/1` returns the active phase.

  ## Usage

      Playbook.start(session_id, :web_app)
      {:ok, phase} = Playbook.current(session_id)
      :ok = Playbook.advance(session_id)
      {:ok, phase} = Playbook.current(session_id)
  """

  require Logger

  @type phase :: %{
          name: String.t(),
          index: non_neg_integer(),
          status: :pending | :in_progress | :complete | :skipped,
          entry_criteria: [String.t()],
          exit_criteria: [String.t()],
          guidance: String.t()
        }

  @type playbook :: %{
          id: atom(),
          name: String.t(),
          phases: [phase()]
        }

  # ── Built-in playbook definitions ──────────────────────────────────────

  @web_app_phases [
    %{
      name: "Scoping & Authorization",
      entry_criteria: ["Targets declared and authorized", "Scope boundaries documented"],
      exit_criteria: ["Target list confirmed", "Out-of-scope assets listed"],
      guidance: "Confirm scope, authorization, and engagement rules. Record targets as notes."
    },
    %{
      name: "Reconnaissance",
      entry_criteria: ["Targets confirmed"],
      exit_criteria: ["Subdomains enumerated", "Technologies fingerprinted", "WAF/CDN detected"],
      guidance:
        "Subdomain enumeration (subfinder), tech fingerprinting (whatweb, wafw00f), DNS recon. Record findings as notes."
    },
    %{
      name: "Enumeration & Mapping",
      entry_criteria: ["Recon complete"],
      exit_criteria: [
        "All web endpoints mapped",
        "Authentication flows understood",
        "API surface documented"
      ],
      guidance:
        "Directory/content discovery (ffuf, gobuster), endpoint mapping, auth flow analysis. Record endpoints as finding notes."
    },
    %{
      name: "Vulnerability Discovery",
      entry_criteria: ["Attack surface mapped"],
      exit_criteria: [
        "All input vectors tested",
        "Automated scan (nuclei) complete",
        "Manual testing of high-value endpoints done"
      ],
      guidance:
        "Automated scanning (nuclei, nikto) + manual testing of injection points, auth issues, business logic. Record vulns as vulnerability notes."
    },
    %{
      name: "Exploitation & Validation",
      entry_criteria: ["Vulnerabilities identified"],
      exit_criteria: [
        "Each vuln reproduced or marked needs-validation",
        "Impact demonstrated",
        "Independent validation done for criticals"
      ],
      guidance:
        "Reproduce findings, demonstrate impact, validate criticals independently. Update note status to confirmed/potential."
    },
    %{
      name: "Reporting",
      entry_criteria: ["Validation complete"],
      exit_criteria: [
        "All findings documented with evidence",
        "Remediation guidance provided",
        "SARIF report generated"
      ],
      guidance:
        "Write the report: per-finding evidence, impact, repro, remediation. Generate SARIF output. Dedup findings."
    }
  ]

  @network_phases [
    %{
      name: "Scoping & Authorization",
      entry_criteria: ["Network ranges declared and authorized"],
      exit_criteria: ["Target ranges confirmed", "Authorization documented"],
      guidance: "Confirm network scope, authorization, and rules of engagement."
    },
    %{
      name: "Host Discovery",
      entry_criteria: ["Ranges confirmed"],
      exit_criteria: ["Live hosts enumerated", "Host inventory recorded as notes"],
      guidance:
        "Host discovery (nmap -sn, masscan). Record discovered hosts as finding notes with target field."
    },
    %{
      name: "Service Enumeration",
      entry_criteria: ["Live hosts known"],
      exit_criteria: [
        "All ports scanned on live hosts",
        "Services identified with versions",
        "Services recorded as notes"
      ],
      guidance:
        "Port scan (nmap -sV), service identification. Record services as finding notes with services array."
    },
    %{
      name: "Vulnerability Discovery",
      entry_criteria: ["Services enumerated"],
      exit_criteria: ["Service vulns researched", "nmap scripts run", "Known CVEs identified"],
      guidance:
        "nmap NSE scripts, version-based CVE lookup, SMB/NetBIOS enum. Record vulns as vulnerability notes."
    },
    %{
      name: "Exploitation & Lateral Movement",
      entry_criteria: ["Vulns identified"],
      exit_criteria: [
        "Credentials obtained or ruled out",
        "Lateral movement attempted or ruled out",
        "Privilege escalation assessed"
      ],
      guidance:
        "Exploit confirmed vulns, test default creds, attempt lateral movement using ShadowGraph insights. Record creds as credential notes."
    },
    %{
      name: "Reporting",
      entry_criteria: ["Exploitation complete"],
      exit_criteria: ["All findings documented", "Network map produced", "SARIF report generated"],
      guidance: "Document the network attack path, findings, and remediation. Generate SARIF."
    }
  ]

  @full_engagement_phases [
    %{
      name: "Scoping & Authorization",
      entry_criteria: ["All targets declared and authorized"],
      exit_criteria: ["Target list confirmed", "Scope boundaries documented"],
      guidance: "Confirm scope across all asset types. Record targets as notes."
    },
    %{
      name: "Reconnaissance",
      entry_criteria: ["Scope confirmed"],
      exit_criteria: ["Subdomains enumerated", "Hosts discovered", "Technologies fingerprinted"],
      guidance:
        "Subdomain + host discovery, tech fingerprinting. Record all discovered assets as notes."
    },
    %{
      name: "Enumeration & Mapping",
      entry_criteria: ["Assets discovered"],
      exit_criteria: [
        "Web endpoints mapped",
        "Network services enumerated",
        "Attack surface documented"
      ],
      guidance:
        "Web endpoint mapping + network service enumeration. Record endpoints and services as finding notes."
    },
    %{
      name: "Vulnerability Discovery",
      entry_criteria: ["Attack surface mapped"],
      exit_criteria: [
        "Web vulns identified",
        "Network vulns identified",
        "Automated scans complete"
      ],
      guidance:
        "Web scanning (nuclei) + network vuln discovery (nmap NSE). Record all vulns as vulnerability notes."
    },
    %{
      name: "Exploitation & Validation",
      entry_criteria: ["Vulnerabilities identified"],
      exit_criteria: [
        "Criticals reproduced",
        "Impact demonstrated",
        "Independent validation done"
      ],
      guidance: "Exploit and validate findings across web + network. Update note statuses."
    },
    %{
      name: "Post-Exploitation",
      entry_criteria: ["Exploitation successful"],
      exit_criteria: [
        "Privilege escalation assessed",
        "Lateral movement mapped",
        "Persistence assessed"
      ],
      guidance:
        "Privilege escalation, lateral movement (use ShadowGraph), persistence. Record new creds and access as notes."
    },
    %{
      name: "Reporting",
      entry_criteria: ["Testing complete"],
      exit_criteria: [
        "Findings documented with evidence",
        "Remediation guidance provided",
        "SARIF report generated"
      ],
      guidance: "Write the full report across all asset types. Generate SARIF. Dedup findings."
    },
    %{
      name: "Review & Handoff",
      entry_criteria: ["Report drafted"],
      exit_criteria: [
        "Findings reviewed for quality",
        "False positives removed",
        "Report delivered"
      ],
      guidance:
        "Review all findings for false positives, calibrate severity, finalize and deliver."
    }
  ]

  @playbooks %{
    web_app: %{id: :web_app, name: "Web Application Assessment", phases: @web_app_phases},
    network: %{id: :network, name: "Internal Network Pentest", phases: @network_phases},
    full_engagement: %{
      id: :full_engagement,
      name: "Full Engagement",
      phases: @full_engagement_phases
    }
  }

  @doc "List available playbook ids."
  @spec available() :: [atom()]
  def available, do: Map.keys(@playbooks)

  @doc "Get a playbook definition by id."
  @spec get(atom()) :: {:ok, playbook()} | {:error, String.t()}
  def get(id) when is_atom(id) do
    case Map.get(@playbooks, id) do
      nil -> {:error, "Unknown playbook: #{id}. Available: #{inspect(Map.keys(@playbooks))}"}
      pb -> {:ok, pb}
    end
  end

  @doc "Get all playbook definitions."
  @spec all() :: [playbook()]
  def all, do: Map.values(@playbooks)

  @doc "Get a phase by index from a playbook."
  @spec phase_at(playbook(), non_neg_integer()) :: {:ok, phase()} | {:error, String.t()}
  def phase_at(%{phases: phases}, index) when is_integer(index) and index >= 0 do
    case Enum.at(phases, index) do
      nil -> {:error, "No phase at index #{index}"}
      phase -> {:ok, Map.merge(phase, %{index: index, status: :pending})}
    end
  end

  @doc "Total phase count for a playbook."
  @spec phase_count(playbook()) :: non_neg_integer()
  def phase_count(%{phases: phases}), do: length(phases)

  # ── Session state (delegates to PlaybookStore) ──────────────────────────

  @doc "Start a playbook for a session. Sets phase 0 to :in_progress."
  @spec start(String.t(), atom()) :: {:ok, playbook()} | {:error, String.t()}
  def start(session_id, playbook_id) when is_binary(session_id) and is_atom(playbook_id) do
    with {:ok, _} <- OptimalSystemAgent.Security.PlaybookStore.ensure_started(session_id),
         {:ok, pb} <- get(playbook_id) do
      OptimalSystemAgent.Security.PlaybookStore.set(session_id, playbook_id, 0, :in_progress)
      {:ok, pb}
    end
  end

  @doc "Get the current phase for a session."
  @spec current(String.t()) :: {:ok, phase()} | {:error, String.t()}
  def current(session_id) when is_binary(session_id) do
    with {:ok, _} <- OptimalSystemAgent.Security.PlaybookStore.ensure_started(session_id) do
      case OptimalSystemAgent.Security.PlaybookStore.get(session_id) do
        {:ok, %{playbook_id: pb_id, phase_index: idx, status: status}} ->
          with {:ok, pb} <- get(pb_id),
               {:ok, phase} <- phase_at(pb, idx) do
            {:ok, %{phase | status: status}}
          end

        :not_found ->
          {:error, "No playbook active for this session. Call Playbook.start/2 first."}
      end
    end
  end

  @doc "Advance to the next phase. Returns the new phase or :complete."
  @spec advance(String.t()) :: {:ok, phase()} | :complete | {:error, String.t()}
  def advance(session_id) when is_binary(session_id) do
    with {:ok, _} <- OptimalSystemAgent.Security.PlaybookStore.ensure_started(session_id) do
      case OptimalSystemAgent.Security.PlaybookStore.get(session_id) do
        {:ok, %{playbook_id: pb_id, phase_index: idx, status: _status}} ->
          with {:ok, pb} <- get(pb_id) do
            next_idx = idx + 1

            if next_idx >= phase_count(pb) do
              OptimalSystemAgent.Security.PlaybookStore.set(session_id, pb_id, idx, :complete)
              :complete
            else
              OptimalSystemAgent.Security.PlaybookStore.set(
                session_id,
                pb_id,
                next_idx,
                :in_progress
              )

              with {:ok, phase} <- phase_at(pb, next_idx) do
                {:ok, Map.put(phase, :status, :in_progress)}
              end
            end
          end

        :not_found ->
          {:error, "No playbook active for this session."}
      end
    end
  end

  @doc "Set the status of the current phase without advancing."
  @spec set_status(String.t(), atom()) :: :ok | {:error, String.t()}
  def set_status(session_id, status)
      when is_binary(session_id) and status in [:pending, :in_progress, :complete, :skipped] do
    with {:ok, _} <- OptimalSystemAgent.Security.PlaybookStore.ensure_started(session_id) do
      case OptimalSystemAgent.Security.PlaybookStore.get(session_id) do
        {:ok, %{playbook_id: pb_id, phase_index: idx}} ->
          OptimalSystemAgent.Security.PlaybookStore.set(session_id, pb_id, idx, status)

        :not_found ->
          {:error, "No playbook active for this session."}
      end
    end
  end

  @doc "Get the full phase list with statuses for a session."
  @spec phases(String.t()) :: {:ok, [phase()]} | {:error, String.t()}
  def phases(session_id) when is_binary(session_id) do
    with {:ok, _} <- OptimalSystemAgent.Security.PlaybookStore.ensure_started(session_id) do
      case OptimalSystemAgent.Security.PlaybookStore.get(session_id) do
        {:ok, %{playbook_id: pb_id, phase_index: current_idx, status: current_status}} ->
          with {:ok, pb} <- get(pb_id) do
            indexed =
              pb.phases
              |> Enum.with_index()
              |> Enum.map(fn {phase, idx} ->
                status =
                  cond do
                    idx < current_idx -> :complete
                    idx == current_idx -> current_status
                    true -> :pending
                  end

                Map.merge(phase, %{index: idx, status: status})
              end)

            {:ok, indexed}
          end

        :not_found ->
          {:error, "No playbook active for this session."}
      end
    end
  end

  @doc "Render the current phase as a prompt-injectable block."
  @spec render_phase(phase()) :: String.t()
  def render_phase(%{} = phase) do
    """
    <current_phase>
    Phase #{phase.index + 1}: #{phase.name}
    Status: #{phase.status}

    Entry criteria:
    #{format_list(phase.entry_criteria)}

    Exit criteria (meet these to advance):
    #{format_list(phase.exit_criteria)}

    Guidance:
    #{phase.guidance}
    </current_phase>
    """
  end

  defp format_list([]), do: "  (none)"
  defp format_list(items), do: Enum.map_join(items, "\n", fn i -> "  - #{i}" end)
end
