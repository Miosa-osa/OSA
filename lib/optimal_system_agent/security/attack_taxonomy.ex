defmodule OptimalSystemAgent.Security.AttackTaxonomy do
  @moduledoc """
  Curated MITRE ATT&CK technique catalog for tagging findings.

  Not the full STIX bundle - the subset that maps onto the vuln classes OSA
  actually produces, plus enough of the kill chain to emit a Navigator layer
  and a coverage report (tried vs untried tactics).
  """

  @techniques [
    %{
      id: "T1595",
      name: "Active Scanning",
      tactic: :reconnaissance,
      url: "https://attack.mitre.org/techniques/T1595/"
    },
    %{
      id: "T1592",
      name: "Gather Victim Host Information",
      tactic: :reconnaissance,
      url: "https://attack.mitre.org/techniques/T1592/"
    },
    %{
      id: "T1190",
      name: "Exploit Public-Facing Application",
      tactic: :initial_access,
      url: "https://attack.mitre.org/techniques/T1190/"
    },
    %{
      id: "T1133",
      name: "External Remote Services",
      tactic: :initial_access,
      url: "https://attack.mitre.org/techniques/T1133/"
    },
    %{
      id: "T1078",
      name: "Valid Accounts",
      tactic: :initial_access,
      url: "https://attack.mitre.org/techniques/T1078/"
    },
    %{
      id: "T1566",
      name: "Phishing",
      tactic: :initial_access,
      url: "https://attack.mitre.org/techniques/T1566/"
    },
    %{
      id: "T1059",
      name: "Command and Scripting Interpreter",
      tactic: :execution,
      url: "https://attack.mitre.org/techniques/T1059/"
    },
    %{
      id: "T1203",
      name: "Exploitation for Client Execution",
      tactic: :execution,
      url: "https://attack.mitre.org/techniques/T1203/"
    },
    %{
      id: "T1053",
      name: "Scheduled Task/Job",
      tactic: :persistence,
      url: "https://attack.mitre.org/techniques/T1053/"
    },
    %{
      id: "T1098",
      name: "Account Manipulation",
      tactic: :persistence,
      url: "https://attack.mitre.org/techniques/T1098/"
    },
    %{
      id: "T1547",
      name: "Boot or Logon Autostart Execution",
      tactic: :persistence,
      url: "https://attack.mitre.org/techniques/T1547/"
    },
    %{
      id: "T1068",
      name: "Exploitation for Privilege Escalation",
      tactic: :privilege_escalation,
      url: "https://attack.mitre.org/techniques/T1068/"
    },
    %{
      id: "T1548",
      name: "Abuse Elevation Control Mechanism",
      tactic: :privilege_escalation,
      url: "https://attack.mitre.org/techniques/T1548/"
    },
    %{
      id: "T1110",
      name: "Brute Force",
      tactic: :credential_access,
      url: "https://attack.mitre.org/techniques/T1110/"
    },
    %{
      id: "T1003",
      name: "OS Credential Dumping",
      tactic: :credential_access,
      url: "https://attack.mitre.org/techniques/T1003/"
    },
    %{
      id: "T1550",
      name: "Use Alternate Authentication Material",
      tactic: :credential_access,
      url: "https://attack.mitre.org/techniques/T1550/"
    },
    %{
      id: "T1083",
      name: "File and Directory Discovery",
      tactic: :discovery,
      url: "https://attack.mitre.org/techniques/T1083/"
    },
    %{
      id: "T1046",
      name: "Network Service Discovery",
      tactic: :discovery,
      url: "https://attack.mitre.org/techniques/T1046/"
    },
    %{
      id: "T1018",
      name: "Remote System Discovery",
      tactic: :discovery,
      url: "https://attack.mitre.org/techniques/T1018/"
    },
    %{
      id: "T1021",
      name: "Remote Services",
      tactic: :lateral_movement,
      url: "https://attack.mitre.org/techniques/T1021/"
    },
    %{
      id: "T1210",
      name: "Exploitation of Remote Services",
      tactic: :lateral_movement,
      url: "https://attack.mitre.org/techniques/T1210/"
    },
    %{
      id: "T1552",
      name: "Unsecured Credentials",
      tactic: :credential_access,
      url: "https://attack.mitre.org/techniques/T1552/"
    },
    %{
      id: "T1005",
      name: "Data from Local System",
      tactic: :collection,
      url: "https://attack.mitre.org/techniques/T1005/"
    },
    %{
      id: "T1114",
      name: "Email Collection",
      tactic: :collection,
      url: "https://attack.mitre.org/techniques/T1114/"
    },
    %{
      id: "T1041",
      name: "Exfiltration Over C2 Channel",
      tactic: :exfiltration,
      url: "https://attack.mitre.org/techniques/T1041/"
    },
    %{
      id: "T1048",
      name: "Exfiltration Over Alternative Protocol",
      tactic: :exfiltration,
      url: "https://attack.mitre.org/techniques/T1048/"
    },
    %{
      id: "T1485",
      name: "Data Destruction",
      tactic: :impact,
      url: "https://attack.mitre.org/techniques/T1485/"
    },
    %{
      id: "T1486",
      name: "Data Encrypted for Impact",
      tactic: :impact,
      url: "https://attack.mitre.org/techniques/T1486/"
    },
    %{
      id: "T1498",
      name: "Network Denial of Service",
      tactic: :impact,
      url: "https://attack.mitre.org/techniques/T1498/"
    },
    %{
      id: "T1055",
      name: "Process Injection",
      tactic: :defense_evasion,
      url: "https://attack.mitre.org/techniques/T1055/"
    },
    %{
      id: "T1027",
      name: "Obfuscated Files or Information",
      tactic: :defense_evasion,
      url: "https://attack.mitre.org/techniques/T1027/"
    },
    %{
      id: "T1071",
      name: "Application Layer Protocol",
      tactic: :command_and_control,
      url: "https://attack.mitre.org/techniques/T1071/"
    },
    %{
      id: "T1570",
      name: "Lateral Tool Transfer",
      tactic: :lateral_movement,
      url: "https://attack.mitre.org/techniques/T1570/"
    },
    %{
      id: "T1537",
      name: "Transfer Data to Cloud Account",
      tactic: :exfiltration,
      url: "https://attack.mitre.org/techniques/T1537/"
    },
    %{
      id: "T1556",
      name: "Modify Authentication Process",
      tactic: :credential_access,
      url: "https://attack.mitre.org/techniques/T1556/"
    }
  ]

  @by_id Map.new(@techniques, &{&1.id, &1})

  @class_map %{
    sqli: "T1190",
    rce: "T1190",
    command_injection: "T1059",
    xss: "T1189",
    ssrf: "T1090",
    idor: "T1078",
    auth_bypass: "T1078",
    path_traversal: "T1083",
    lfi: "T1083",
    xxe: "T1190",
    ssti: "T1059",
    deserialization: "T1190",
    csrf: "T1078",
    open_redirect: "T1566",
    privilege_escalation: "T1068",
    hardcoded_secret: "T1552",
    weak_crypto: "T1552",
    request_smuggling: "T1190",
    prototype_pollution: "T1059",
    nosql: "T1190"
  }

  @tactics Enum.map(@techniques, & &1.tactic) |> Enum.uniq()

  @spec all() :: [map()]
  def all, do: @techniques

  @spec lookup(String.t() | atom()) :: map() | nil
  def lookup(id) when is_atom(id),
    do: lookup(id |> Atom.to_string() |> String.replace_prefix("Elixir.", ""))

  def lookup("T" <> _ = id), do: Map.get(@by_id, id)
  def lookup(id) when is_binary(id), do: Map.get(@by_id, id)
  def lookup(_), do: nil

  @spec by_tactic(atom()) :: [map()]
  def by_tactic(tactic) when is_atom(tactic) do
    Enum.filter(@techniques, &(&1.tactic == tactic))
  end

  def by_tactic(_), do: []

  @doc "Best-effort map from a vuln class or finding to a technique."
  @spec tag(atom() | map()) :: map() | nil
  def tag(class) when is_atom(class) do
    case Map.get(@class_map, class) do
      nil ->
        nil

      id ->
        case lookup(id) do
          nil -> %{technique_id: id, tactic: :initial_access, name: id}
          t -> %{technique_id: t.id, tactic: t.tactic, name: t.name}
        end
    end
  end

  def tag(%{} = finding) do
    class = Map.get(finding, :vuln_class) || Map.get(finding, "vuln_class")
    class = if is_binary(class), do: safe_atom(class), else: class
    tag(class)
  end

  def tag(_), do: nil

  @spec coverage_report([String.t()]) :: map()
  def coverage_report(ids) when is_list(ids) do
    tried_ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    tried = Enum.filter(@techniques, &(&1.id in tried_ids))
    untried = Enum.reject(@techniques, &(&1.id in tried_ids))
    tactics_covered = tried |> Enum.map(& &1.tactic) |> Enum.uniq()
    tactics_missing = @tactics -- tactics_covered

    %{
      tried: Enum.map(tried, & &1.id),
      untried: Enum.map(untried, & &1.id),
      tactics_covered: tactics_covered,
      tactics_missing: tactics_missing
    }
  end

  def coverage_report(_),
    do: %{
      tried: [],
      untried: Enum.map(@techniques, & &1.id),
      tactics_covered: [],
      tactics_missing: @tactics
    }

  @doc "MITRE ATT&CK Navigator layer JSON (map)."
  @spec navigator_layer([String.t()], keyword()) :: map()
  def navigator_layer(ids, opts \\ []) when is_list(ids) do
    name = Keyword.get(opts, :name, "OSA engagement")

    techniques =
      ids
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(@by_id, &1))
      |> Enum.map(fn id -> %{"techniqueID" => id, "score" => 1} end)

    %{
      "name" => name,
      "versions" => %{"attack" => "14", "navigator" => "4.9", "layer" => "4.5"},
      "domain" => "enterprise-attack",
      "techniques" => techniques
    }
  end

  defp safe_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end
end
