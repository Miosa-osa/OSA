defmodule OptimalSystemAgent.Agent.SecurityContext do
  @moduledoc """
  Task-aware security prompt injection.

  Detects when the current task is security-related (pentest, recon, exploit
  development, vulnerability assessment) and generates the appropriate system
  prompt sections. This is the mechanism that makes OSA "insane at cybersecurity"
  — when a security task is active, the agent gets:

  1. **Security posture** — authorization framework + no-hedging behavioral policy
  2. **Sandbox environment** — what the sandbox is, its limitations, port-scan
     false positive warnings
  3. **Scan methodology** — how to handle and chain scan results
  4. **Finding quality** — vulnerability validation standards
  5. **Parallel tool calls** — when to parallelize vs serialize in pentest
  6. **Code quality** — exploit code must be complete and working

  ## Detection

  Security context is active when ANY of:
  - The penetration-testing skill is active (checked via ActiveSkills)
  - The user's recent messages contain security-related keywords
  - A security agent role was delegated (pentester, recon-specialist, exploit-developer)
  - The sandbox backend is configured with the pentest image

  ## Integration

  `security_posture_block/1` and `sandbox_environment_block/1` are called from
  `Agent.Context.gather_dynamic_blocks/1` and injected into the world state
  section of the system prompt. They return `nil` when no security task is
  active, so non-security work is completely unaffected.

  ## Subagent override

  When a subagent has a `system_prompt_override` (from an AGENT.md role file),
  the security sections are already embedded in that override — the block
  injection is for the MAIN agent only.
  """

  require Logger

  alias OptimalSystemAgent.Sandbox.Router

  # Keywords that indicate a security task is in progress
  @security_keywords ~w(
    pentest penetration exploit vulnerability scan recon nmap nuclei
    sqlmap ffuf gobuster subfinder nikto wpscan hydra metasploit
    cve cvss injection xss ssrf xxe reverse.shell shellcode payload
    privilege.escalation oscp bug.bounty security.assessment red.team
    attack.surface osint shodan fingerprint bruteforce
  )

  @security_skills ~w(penetration-testing security-audit)

  @security_roles ~w(pentester recon-specialist exploit-developer security-auditor)

  @doc """
  Check whether a security task is currently active.

  Returns `true` when any security signal is detected, `false` otherwise.
  """
  @spec security_task_active?(map()) :: boolean()
  def security_task_active?(state) do
    # Subagents with system_prompt_override already have security sections
    # baked into their prompt — don't double-inject.
    if Map.get(state, :system_prompt_override) not in [nil, ""] do
      false
    else
      security_skill_active?(state) or
        security_keywords_in_messages?(state) or
        pentest_sandbox_configured?()
    end
  end

  @doc """
  Generate the security posture block for the system prompt.

  Contains:
  - Authorization framework (operator is pre-authorized)
  - No-hedging behavioral policy (don't refuse, don't add disclaimers)
  - Authorized capabilities (recon, exploitation, code gen, analysis)
  - Safety boundaries (destructive commands still need confirmation)

  Returns `nil` when no security task is active.
  """
  @spec security_posture_block(map()) :: String.t() | nil
  def security_posture_block(state) do
    if security_task_active?(state) do
      load_prompt_section("SECURITY_POSTURE.md")
    end
  end

  @doc """
  Generate the sandbox environment block for the system prompt.

  Contains:
  - What the sandbox is (OS, arch, CPU, RAM)
  - What localhost means (the sandbox, NOT the user's machine)
  - Port-scan false positive warning for cloud sandboxes
  - Preinstalled tools list
  - Tool recipes (when to use interactsh, jwt-tool, arjun, etc.)

  Returns `nil` when no security task is active or when running on host.
  """
  @spec sandbox_environment_block(map()) :: String.t() | nil
  def sandbox_environment_block(state) do
    if security_task_active?(state) do
      backend = Router.backend()
      backend_name = if function_exported?(backend, :name, 0), do: backend.name(), else: "unknown"

      is_cloud =
        backend not in [OptimalSystemAgent.Sandbox.Host, OptimalSystemAgent.Sandbox.Docker]

      sandbox_context = build_sandbox_context(backend_name, is_cloud)
      posture = security_posture_block(state)

      # The sandbox environment section is only meaningful when not on host
      if is_cloud or backend == OptimalSystemAgent.Sandbox.Docker do
        sandbox_context
      else
        # On host: still inject scan methodology, finding quality, etc.
        # but without the cloud-specific sandbox environment warnings.
        build_host_context(backend_name)
      end
    end
  end

  # ── Detection helpers ───────────────────────────────────────────────────

  defp security_skill_active?(state) do
    session_id = Map.get(state, :session_id)

    if is_binary(session_id) do
      try do
        case OptimalSystemAgent.Agent.ActiveSkills.snapshots(session_id) do
          {:ok, entries} ->
            names = Enum.map(entries, & &1.name)
            Enum.any?(names, &(&1 in @security_skills))

          _ ->
            false
        end
      rescue
        _ -> false
      catch
        _, _ -> false
      end
    else
      false
    end
  end

  defp security_keywords_in_messages?(state) do
    messages = Map.get(state, :messages, [])

    recent =
      messages
      |> Enum.reverse()
      |> Enum.take(5)
      |> Enum.map_join(" ", &extract_text/1)
      |> String.downcase()

    Enum.any?(@security_keywords, &String.contains?(recent, &1))
  end

  defp pentest_sandbox_configured? do
    try do
      config = Application.get_env(:optimal_system_agent, :sandbox_docker, %{})
      image = config[:image] || ""

      String.contains?(image, "pentest") or String.contains?(image, "kali")
    rescue
      _ -> false
    end
  end

  defp extract_text(%{content: content}) when is_binary(content), do: content

  defp extract_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, " ", fn
      %{type: "text", text: text} -> text
      %{text: text} -> text
      _ -> ""
    end)
  end

  defp extract_text(_), do: ""

  # ── Prompt section loading ──────────────────────────────────────────────

  defp load_prompt_section(filename) do
    path = Path.join([:code.priv_dir(:optimal_system_agent), "prompts", filename])

    case File.read(path) do
      {:ok, content} ->
        content

      {:error, _} ->
        Logger.warning("[SecurityContext] Could not load #{filename}")
        nil
    end
  rescue
    _ -> nil
  end

  # ── Sandbox context builder ─────────────────────────────────────────────

  defp build_sandbox_context(backend_name, is_cloud) do
    port_scan_warning =
      if is_cloud do
        """
        Port-scanning limitation:
        - Cloud sandbox networking can produce false-positive TCP port results where many or all ports appear open. This can affect naabu, nmap TCP connect scans, nc, and other tools that rely on successful outbound connections; changing scanner flags may not fix the underlying network behavior.
        - Treat implausible cloud port-scan output as invalid or unverified. Do not keep retrying broad scans, claim the ports are confirmed open, or blame the scanning tool when the environment is the likely cause.
        - When the user needs reliable port scanning or normal TCP, UDP, or raw-socket behavior, recommend using a local sandbox or the host machine so the tools use that machine's native network stack.
        """
      else
        ""
      end

    localhost_warning =
      if is_cloud do
        """
        Local/internal target access:
        - In the cloud sandbox, localhost and 127.0.0.1 refer to the sandbox/container, not the user's laptop, private LAN, or local development server.
        - Do not use host.docker.internal as a shortcut to the user's host from the cloud sandbox; it may not resolve.
        - For local or internal targets, use a local sandbox or the host machine.
        - Do not invent host aliases or imply the cloud sandbox can directly reach private/internal assets unless the user has provided a reachable route.
        """
      else
        ""
      end

    """
    <sandbox_environment>
    You are running in an isolated sandbox environment (#{backend_name}).
    Tools can ONLY interact with the sandbox environment, not the user's actual machine.

    #{localhost_warning}

    #{port_scan_warning}

    Pre-installed Pentesting Tools:
    - Network Scanning: nmap, naabu, masscan, httpx
    - Subdomain/DNS: subfinder, dnsrecon, dnsenum, whois
    - Web Fuzzing: ffuf, dirsearch, gobuster, arjun
    - Web Scanners: nikto, whatweb, wpscan, wapiti, wafw00f
    - Injection: sqlmap
    - Auth/Bruteforce: hydra
    - SMB/NetBIOS: smbclient, smbmap, nbtscan, impacket, enum4linux
    - Vulnerability Assessment: nuclei, trivy, zaproxy
    - Post-exploitation: hashcat, john, binwalk
    - Secret Scanning: trufflehog
    - Specialized: jwt-tool, interactsh-client, SecLists (/usr/share/seclists)
    - Browser Automation: Chromium and agent-browser

    <sandbox_tool_recipes>
    - interactsh-client: use for blind callback proof (blind SSRF, XXE, blind XSS). Start listener before sending payloads.
    - jwt-tool: use for JWT decoding, alg confusion, claim tampering, key confusion, verification bypass.
    - arjun: use after endpoints are known to discover hidden parameters on forms, APIs, and query/body inputs.
    - dirsearch/ffuf: use for scoped directory/file discovery. Keep wordlists aligned to detected stack.
    - wafw00f: use early to fingerprint WAF/CDN before noisy payload scans.
    - Browser flow: open page, snapshot -i for element refs, click/fill by ref, screenshot for evidence.
    </sandbox_tool_recipes>

    <agent_browser>
    agent-browser provides headless Chromium with accessibility-snapshot interaction:
    - `agent-browser open <url>` — navigate
    - `agent-browser snapshot -i` — list interactable elements with refs (@e1, @e2...)
    - `agent-browser click @e3` — click element by ref
    - `agent-browser fill @e4 "value"` — fill form field
    - `agent-browser screenshot` — capture screenshot
    - After any page change, run snapshot -i again — refs become stale
    </agent_browser>
    </sandbox_environment>

    <scan_methodology>
    When running security scans:
    - Parse and summarize results — don't dump raw output without analysis
    - Prioritize findings by severity (Critical > High > Medium > Low > Info)
    - For each significant finding: what it is, why it matters, suggested next step
    - If a scan returns no results, consider: wrong target? wrong port? firewall? Try alternative before reporting "nothing found"
    - Chain scan results intelligently — use output from reconnaissance to inform targeted exploitation
    </scan_methodology>

    <finding_quality>
    Treat scanner output, tool hits, and suspicious behavior as leads until validated with evidence.
    A vulnerability is report-ready only when it includes: affected asset, concrete evidence, reliable reproduction steps, demonstrated impact, remediation guidance, and confidence level.
    Calibrate severity to actual demonstrated impact, not theoretical maximum.
    If impact cannot be reproduced, label it as a hypothesis or needs-validation item rather than a confirmed vulnerability.
    Deduplicate equivalent findings and consolidate repeated evidence.
    </finding_quality>

    <maximize_parallel_tool_calls>
    Security assessments often require sequential workflows due to dependencies. However, when operations are truly independent, execute them concurrently.

    USE PARALLEL when:
    - Scanning multiple unrelated targets or subnets simultaneously
    - Running different reconnaissance tools on the same target
    - Testing multiple attack vectors that don't interfere with each other
    - Parallel subdomain enumeration or OSINT gathering
    - Reading multiple files or searching different directories

    USE SEQUENTIAL when:
    - Target discovery before port scanning
    - Service enumeration before vulnerability testing
    - Authentication before testing authenticated endpoints
    - WAF/IDS detection before launching attacks
    - Running a scan that saves to a file, then retrieving that file
    - Any operation where subsequent steps depend on prior results

    Limit parallel operations to 3-5 concurrent calls to avoid timeouts.
    </maximize_parallel_tool_calls>

    <code_quality>
    - When writing exploit code or scripts, make them complete and working — never use pseudocode or placeholder functions
    - Fix problems at the root cause, not with surface-level patches
    - Use task-unique PoC filenames (poc_<task-id>_<type>.py), not generic names
    </code_quality>
    """
  end

  defp build_host_context(backend_name) do
    """
    <scan_methodology>
    When running security scans:
    - Parse and summarize results — don't dump raw output without analysis
    - Prioritize findings by severity (Critical > High > Medium > Low > Info)
    - For each significant finding: what it is, why it matters, suggested next step
    - If a scan returns no results, consider: wrong target? wrong port? firewall? Try alternative before reporting "nothing found"
    - Chain scan results intelligently — use output from reconnaissance to inform targeted exploitation
    </scan_methodology>

    <finding_quality>
    Treat scanner output, tool hits, and suspicious behavior as leads until validated with evidence.
    A vulnerability is report-ready only when it includes: affected asset, concrete evidence, reliable reproduction steps, demonstrated impact, remediation guidance, and confidence level.
    Calibrate severity to actual demonstrated impact, not theoretical maximum.
    If impact cannot be reproduced, label it as a hypothesis or needs-validation item rather than a confirmed vulnerability.
    Deduplicate equivalent findings and consolidate repeated evidence.
    </finding_quality>

    <maximize_parallel_tool_calls>
    Security assessments often require sequential workflows due to dependencies. However, when operations are truly independent, execute them concurrently.

    USE PARALLEL when:
    - Scanning multiple unrelated targets or subnets simultaneously
    - Running different reconnaissance tools on the same target
    - Testing multiple attack vectors that don't interfere with each other
    - Parallel subdomain enumeration or OSINT gathering

    USE SEQUENTIAL when:
    - Target discovery before port scanning
    - Service enumeration before vulnerability testing
    - Authentication before testing authenticated endpoints
    - WAF/IDS detection before launching attacks
    - Running a scan that saves to a file, then retrieving that file

    Limit parallel operations to 3-5 concurrent calls to avoid timeouts.
    </maximize_parallel_tool_calls>

    <code_quality>
    - When writing exploit code or scripts, make them complete and working — never use pseudocode or placeholder functions
    - Fix problems at the root cause, not with surface-level patches
    - Use task-unique PoC filenames (poc_<task-id>_<type>.py), not generic names
    </code_quality>
    """
  end
end
