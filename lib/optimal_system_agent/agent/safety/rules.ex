defmodule OptimalSystemAgent.Agent.Safety.Rules do
  @moduledoc """
  POLICY DATA for the auto-mode safety classifier.

  This module is deliberately dumb: it holds the matcher tables for the threat
  categories and a couple of tiny, pure helper functions to run those tables
  against a string. It performs **no I/O**, keeps **no state**, and makes **no
  decisions** about what to do with a match — that is the job of `Classifier`
  (folding) and `Guardian` (enforcement).

  Each category is a list of `{label, regex}` tuples. `match/2` returns the first
  matching `{label, regex}` for a category (or `nil`), and `first_match/1` scans
  every category and returns `{category, label}` for the first hit.

  The `prompt_injection_driven` category has no regex table here — it is
  delegated to `PromptInjection.prompt_injection?/1` by the classifier, since that
  detector already implements three-tier unicode-aware analysis.
  """

  @type label :: String.t()
  @type category :: atom()
  @type rule :: {label(), Regex.t()}

  # ── privilege_escalation ────────────────────────────────────────────
  # sudo / su / chmod 777 / setuid / pkexec / doas
  @privilege_escalation [
    {"sudo", ~r/(?:^|[\s;&|(])sudo\b/i},
    {"su -", ~r/(?:^|[\s;&|(])su\b(?:\s+-|\s+root|\s*$)/i},
    {"doas", ~r/(?:^|[\s;&|(])doas\b/i},
    {"pkexec", ~r/(?:^|[\s;&|(])pkexec\b/i},
    {"chmod 777", ~r/\bchmod\s+(?:-\S+\s+)*(?:0?777|a\+rwx|ugo\+rwx)\b/i},
    {"chmod +s / setuid", ~r/\bchmod\s+(?:-\S+\s+)*(?:[ug]?\+s|[0-9]*[47][0-7]{3})\b/i},
    {"setcap", ~r/\bsetcap\b/i},
    {"chown root", ~r/\bchown\s+(?:-\S+\s+)*root\b/i}
  ]

  # ── force_push ──────────────────────────────────────────────────────
  # git push --force / -f / +refs / push --delete
  @force_push [
    {"git push --force", ~r/\bgit\s+push\b[^\n]*(?:--force\b|--force-with-lease\b)/i},
    {"git push -f", ~r/\bgit\s+push\b[^\n]*(?:^|\s)-\w*f\w*\b/i},
    {"git push +refs", ~r/\bgit\s+push\b[^\n]*\s\+[\w\/]+/},
    {"git push --delete", ~r/\bgit\s+push\b[^\n]*(?:--delete\b|\s:[\w\/]+)/i}
  ]

  # ── prod_deploy ─────────────────────────────────────────────────────
  # kubectl -n prod, terraform apply, helm upgrade, gcloud run deploy,
  # fly deploy, wrangler publish
  @prod_deploy [
    {"kubectl prod",
     ~r/\bkubectl\b[^\n]*(?:-n|--namespace[=\s])\s*["']?(?:prod|production|prd|live)\b/i},
    {"kubectl apply/delete",
     ~r/\bkubectl\s+(?:apply|delete|replace|scale|rollout|drain|cordon)\b/i},
    {"terraform apply", ~r/\bterraform\s+(?:apply|destroy)\b/i},
    {"helm upgrade", ~r/\bhelm\s+(?:upgrade|install|delete|uninstall|rollback)\b/i},
    {"gcloud run deploy", ~r/\bgcloud\s+(?:run\s+deploy|app\s+deploy|deploy)\b/i},
    {"fly deploy", ~r/\bfly(?:ctl)?\s+deploy\b/i},
    {"wrangler publish", ~r/\bwrangler\s+(?:publish|deploy)\b/i},
    {"vercel --prod", ~r/\bvercel\b[^\n]*(?:--prod|--production)\b/i},
    {"aws deploy", ~r/\baws\s+(?:deploy|ecs\s+update-service|lambda\s+update)\b/i}
  ]

  # ── secret_exfiltration ─────────────────────────────────────────────
  # reading .env/.ssh/id_*/credentials/*.pem then piping to curl|nc|base64|host;
  # env dumps
  @secret_paths ~S"(?:\.env\b|\.ssh\/|id_(?:rsa|ed25519|ecdsa|dsa)\b|credentials\b|\.pem\b|\.p12\b|\.key\b|\.aws\/|\.netrc\b|secrets?\b)"
  @exfil_sink ~S"(?:curl|wget|nc\b|ncat|netcat|base64|xxd|scp|ssh\b|http[s]?:\/\/|@[\w.-]+:)"
  @secret_exfiltration [
    {"read secret then pipe to network/encoder",
     ~r/#{@secret_paths}[^\n]*\|[^\n]*#{@exfil_sink}/i},
    {"cat/read secret piped out",
     ~r/\b(?:cat|less|head|tail|dd)\b[^\n]*#{@secret_paths}[^\n]*\|/i},
    {"env dump piped out", ~r/\b(?:env|printenv|set)\b[^\n]*\|[^\n]*#{@exfil_sink}/i},
    {"curl exfil of secret", ~r/\bcurl\b[^\n]*(?:-d|--data|-T|--upload-file)[^\n]*#{@secret_paths}/i},
    {"tar secrets to stdout", ~r/\btar\b[^\n]*#{@secret_paths}[^\n]*\|/i}
  ]

  # ── mass_delete ─────────────────────────────────────────────────────
  # rm -rf broad paths, find -delete, git clean -fdx, DROP TABLE, truncate
  @mass_delete [
    {"rm -rf root/home/broad",
     ~r/\brm\s+(?:-\w*[rf]\w*\s+)+(?:-\w+\s+)*(?:\/|~|\$HOME|\.\.?\/?|\*|\/\*)(?:\s|$)/i},
    {"rm -rf with force+recurse", ~r/\brm\s+(?:-[rf]+\s*){1,}.*(?:-fr|-rf|--recursive.*--force)/i},
    {"find -delete", ~r/\bfind\b[^\n]*-delete\b/i},
    {"find -exec rm", ~r/\bfind\b[^\n]*-exec\s+rm\b/i},
    {"git clean -fdx", ~r/\bgit\s+clean\b[^\n]*-\w*[fdx]\w*/i},
    {"DROP TABLE/DATABASE", ~r/\bDROP\s+(?:TABLE|DATABASE|SCHEMA)\b/i},
    {"TRUNCATE", ~r/\bTRUNCATE\s+(?:TABLE\s+)?\w/i},
    {"DELETE without WHERE", ~r/\bDELETE\s+FROM\s+\w+\s*(?:;|$)/i},
    {"mkfs / dd to device", ~r/\b(?:mkfs\b|dd\b[^\n]*of=\/dev\/)/i}
  ]

  # ── untrusted_network ───────────────────────────────────────────────
  # curl/wget/nc/ssh to hosts not in the allowlist. The regex only *extracts*
  # candidate hosts; the allowlist decision lives in `network_verdict/2` so the
  # allowlist can be injected from config (Guardian) without I/O here.
  @network_tools ~r/\b(?:curl|wget|nc|ncat|netcat|ssh|scp|sftp|rsync|telnet|ftp)\b/i
  @url_host ~r/\bhttps?:\/\/([^\/\s:'"]+)/i
  @bare_host ~r/\b(?:ssh|scp|sftp)\s+(?:-\w+\s+)*(?:[\w.-]+@)?([\w.-]+\.[a-z]{2,})/i

  # ── loopback / private hosts always considered trusted ──────────────
  @implicit_local ~w(localhost 127.0.0.1 0.0.0.0 ::1 host.docker.internal)

  @doc "Return the matcher table for a category (empty list for delegated ones)."
  @spec table(category()) :: [rule()]
  def table(:privilege_escalation), do: @privilege_escalation
  def table(:force_push), do: @force_push
  def table(:prod_deploy), do: @prod_deploy
  def table(:secret_exfiltration), do: @secret_exfiltration
  def table(:mass_delete), do: @mass_delete
  # untrusted_network is handled specially (needs allowlist) — no static table.
  def table(_), do: []

  @doc """
  Categories evaluated by the pure regex tables, in descending severity order.
  `untrusted_network` and `prompt_injection_driven` are handled separately by
  the classifier (allowlist / delegated detector respectively).
  """
  @spec regex_categories() :: [category()]
  def regex_categories,
    do: [
      :secret_exfiltration,
      :mass_delete,
      :privilege_escalation,
      :prod_deploy,
      :force_push
    ]

  @doc """
  Run a single category's table against `text`. Returns `{label, regex}` for the
  first matching rule, or `nil`.
  """
  @spec match(category(), String.t()) :: rule() | nil
  def match(category, text) when is_binary(text) do
    category
    |> category_table()
    |> Enum.find(fn {_label, re} -> Regex.match?(re, text) end)
  end

  def match(_category, _text), do: nil

  @doc """
  Scan every regex category (in severity order) and return `{category, label}`
  for the first hit, or `nil`. Does not cover `untrusted_network` /
  `prompt_injection_driven`.
  """
  @spec first_match(String.t()) :: {category(), label()} | nil
  def first_match(text) when is_binary(text) do
    Enum.find_value(regex_categories(), fn category ->
      case match(category, text) do
        {label, _re} -> {category, label}
        nil -> nil
      end
    end)
  end

  def first_match(_), do: nil

  @doc """
  Untrusted-network check. Extracts hosts referenced by network tools in `text`
  and returns `{:untrusted_network, host}` for the first host not present in
  `allowlist` (loopback/private hosts are always trusted). Returns `nil` when no
  network tool is used or every host is allowlisted.

  Pure: the allowlist is passed in; no config read, no DNS, no sockets.
  """
  @spec network_match(String.t(), [String.t()]) :: {category(), label()} | nil
  def network_match(text, allowlist) when is_binary(text) and is_list(allowlist) do
    if Regex.match?(@network_tools, text) do
      allowed = allowlist ++ @implicit_local

      text
      |> extract_hosts()
      |> Enum.find(fn host -> not host_allowed?(host, allowed) end)
      |> case do
        nil -> nil
        host -> {:untrusted_network, host}
      end
    else
      nil
    end
  end

  def network_match(_text, _allowlist), do: nil

  @doc "Extract candidate network hosts (URLs + bare ssh/scp targets) from text."
  @spec extract_hosts(String.t()) :: [String.t()]
  def extract_hosts(text) when is_binary(text) do
    url_hosts = Regex.scan(@url_host, text) |> Enum.map(&Enum.at(&1, 1))
    bare_hosts = Regex.scan(@bare_host, text) |> Enum.map(&Enum.at(&1, 1))

    (url_hosts ++ bare_hosts)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  def extract_hosts(_), do: []

  # A host is allowed if it exactly matches, or is a subdomain of, an allowlist
  # entry (e.g. "api.github.com" allowed by "github.com").
  defp host_allowed?(host, allowed) do
    Enum.any?(allowed, fn a ->
      a = String.downcase(a)
      host == a or String.ends_with?(host, "." <> a)
    end)
  end

  # Internal dispatch avoiding the public placeholder for untrusted_network.
  defp category_table(:privilege_escalation), do: @privilege_escalation
  defp category_table(:force_push), do: @force_push
  defp category_table(:prod_deploy), do: @prod_deploy
  defp category_table(:secret_exfiltration), do: @secret_exfiltration
  defp category_table(:mass_delete), do: @mass_delete
  defp category_table(_), do: []
end
