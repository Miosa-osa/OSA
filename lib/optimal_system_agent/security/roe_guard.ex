defmodule OptimalSystemAgent.Security.RoeGuard do
  @moduledoc """
  Rules-of-Engagement scope contract and blast-radius guardrail for offensive
  engagements.

  An autonomous offensive agent must never act outside the target and mandate it
  was given. This module holds a per-session RoE contract - the allowed targets
  (hosts / CIDRs / domains), the forbidden action classes, and an optional time
  window - and classifies a proposed action by **blast radius** so out-of-scope
  or destructive actions can be hard-blocked or routed to a human before they
  run.

  It is intentionally a pure decision function (`check/2`, `classify/1`,
  `in_scope?/2`): the enforcement point (a tool middleware, the shell path, the
  human steer loop) calls it and acts on the verdict. Keeping the policy pure
  makes the authorization decision fully testable without a live target, and
  lets the same contract gate every capability - recon, PoC validation, C2 -
  through one place.

  ## Contract shape

      %{
        targets: ["10.0.0.0/24", "app.example.com", "*.staging.example.com"],
        forbidden: [:destructive, :persistence],   # blast-radius classes to block
        max_blast: :cred_access,                    # allow up to here; block above
        window: {~U[..], ~U[..]} | nil,             # optional engagement window
        contacts: ["soc@example.com"]
      }

  ## Blast-radius ladder (ascending severity)

      :recon        read-only enumeration (scan, fingerprint, list)
      :access       authenticated/exploit access to an in-scope asset
      :cred_access  credential capture / dumping
      :lateral      lateral movement to another in-scope asset
      :persistence  installing persistence / backdoors
      :destructive  data destruction, DoS, or anything irreversible

  Default posture is conservative: no contract loaded => only `:recon` is
  allowed and everything else is `:needs_authorization`, so the guard fails
  safe if the enforcement point ever asks before a contract is set.
  """

  @ladder [:recon, :access, :cred_access, :lateral, :persistence, :destructive]
  @rank @ladder |> Enum.with_index() |> Map.new()

  @type contract :: %{
          optional(:targets) => [String.t()],
          optional(:forbidden) => [atom()],
          optional(:max_blast) => atom(),
          optional(:window) => {DateTime.t(), DateTime.t()} | nil,
          optional(:contacts) => [String.t()]
        }

  @type verdict :: :allow | :block | :needs_authorization

  @doc "The blast-radius ladder, ascending in severity."
  @spec ladder() :: [atom()]
  def ladder, do: @ladder

  @doc """
  Decide whether an action is allowed under a contract.

  `action` is a map: `%{blast: atom(), target: String.t() | nil, now: DateTime.t() | nil}`.
  Returns `{:allow, reason}` | `{:block, reason}` | `{:needs_authorization, reason}`.

  Order of checks (first failure wins, most-decisive first): no contract →
  needs auth; outside window → block; target out of scope → block; blast class
  forbidden → block; blast above `max_blast` → needs auth; otherwise allow.
  """
  @spec check(contract() | nil, map()) :: {verdict(), String.t()}
  def check(nil, %{blast: blast}) do
    if blast == :recon do
      {:allow, "no RoE loaded — read-only recon permitted by default"}
    else
      {:needs_authorization,
       "no RoE contract loaded; #{blast} requires an authorized scope — load one or get human approval"}
    end
  end

  def check(%{} = contract, %{blast: blast} = action) do
    target = Map.get(action, :target)
    now = Map.get(action, :now)

    cond do
      not within_window?(contract, now) ->
        {:block, "outside the engagement time window"}

      not is_nil(target) and not in_scope?(contract, target) ->
        {:block, "target #{inspect(target)} is not in the authorized scope"}

      blast in (contract[:forbidden] || []) ->
        {:block, "#{blast} is a forbidden action class for this engagement"}

      above_max?(contract, blast) ->
        {:needs_authorization,
         "#{blast} exceeds the authorized blast radius (#{contract[:max_blast]}) — human approval required"}

      true ->
        {:allow, "within scope and blast radius"}
    end
  end

  def check(_contract, _action), do: {:needs_authorization, "malformed action"}

  @doc """
  Classify a shell/command string into a blast-radius class by its verbs.

  Heuristic and deliberately conservative: an unknown command is `:access`
  (not `:recon`), so a novel tool is treated as potentially impactful rather
  than waved through. Destructive/persistence patterns dominate.
  """
  @spec classify(String.t()) :: atom()
  def classify(cmd) when is_binary(cmd) do
    c = String.downcase(cmd)

    cond do
      match_any?(
        c,
        ~w(rm\ -rf mkfs dd\ if= shutdown reboot :\(\)\{ drop\ table truncate\ table wipefs)
      ) ->
        :destructive

      match_any?(c, [
        "crontab",
        "systemctl enable",
        "/etc/rc.local",
        "authorized_keys",
        "reg add",
        "schtasks",
        "launchctl load"
      ]) ->
        :persistence

      match_any?(c, [
        "psexec",
        "wmiexec",
        "ssh ",
        "evil-winrm",
        "smbexec",
        "crackmapexec",
        "netexec"
      ]) ->
        :lateral

      match_any?(c, [
        "mimikatz",
        "secretsdump",
        "hashcat",
        "john ",
        "lsass",
        "sam ",
        "ntds",
        "/etc/shadow",
        "gsecdump"
      ]) ->
        :cred_access

      match_any?(c, [
        "sqlmap",
        "metasploit",
        "msfconsole",
        "exploit",
        "nc -e",
        "reverse shell",
        "/bin/sh -i",
        "curl http",
        "wget http"
      ]) ->
        :access

      match_any?(c, [
        "nmap",
        "naabu",
        "masscan",
        "subfinder",
        "httpx",
        "whatweb",
        "nuclei",
        "ffuf",
        "gobuster",
        "amass",
        "dig ",
        "whois",
        "nikto"
      ]) ->
        :recon

      true ->
        :access
    end
  end

  def classify(_), do: :access

  @doc "Is `target` covered by the contract's allowed targets (host, CIDR, or glob domain)?"
  @spec in_scope?(contract(), String.t()) :: boolean()
  def in_scope?(%{targets: targets}, target) when is_list(targets) do
    Enum.any?(targets, &target_matches?(&1, target))
  end

  def in_scope?(_, _), do: false

  # ── internals ─────────────────────────────────────────────────────────────

  defp above_max?(%{max_blast: max}, blast) when is_atom(max) do
    r = Map.get(@rank, blast)
    m = Map.get(@rank, max)
    is_integer(r) and is_integer(m) and r > m
  end

  defp above_max?(_, _), do: false

  defp within_window?(%{window: {from, to}}, %DateTime{} = now) do
    DateTime.compare(now, from) != :lt and DateTime.compare(now, to) != :gt
  end

  # No window, or no clock supplied: not a time-based block.
  defp within_window?(_, _), do: true

  defp target_matches?(rule, target) do
    cond do
      String.contains?(rule, "/") -> cidr_match?(rule, target)
      String.contains?(rule, "*") -> glob_match?(rule, target)
      true -> rule == target
    end
  end

  defp glob_match?(rule, target) do
    pattern =
      rule
      |> Regex.escape()
      |> String.replace("\\*", "[^.]+")

    Regex.match?(~r/\A#{pattern}\z/i, target)
  end

  defp cidr_match?(rule, target) do
    with [net, bits] <- String.split(rule, "/"),
         {bits, ""} <- Integer.parse(bits),
         {:ok, net_ip} <- :inet.parse_address(String.to_charlist(net)),
         {:ok, tgt_ip} <- :inet.parse_address(String.to_charlist(target)) do
      same_prefix?(net_ip, tgt_ip, bits)
    else
      _ -> false
    end
  end

  # IPv4 only (the common engagement case); an IPv6 target simply won't match a
  # v4 CIDR rule, which fails safe (out of scope) rather than falsely allowing.
  defp same_prefix?({a, b, c, d}, {e, f, g, h}, bits) when bits in 0..32 do
    net = <<a, b, c, d>>
    tgt = <<e, f, g, h>>
    <<n::size(bits), _::bitstring>> = net
    <<t::size(bits), _::bitstring>> = tgt
    n == t
  end

  defp same_prefix?(_, _, _), do: false

  defp match_any?(haystack, needles), do: Enum.any?(needles, &String.contains?(haystack, &1))
end
