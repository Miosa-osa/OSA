defmodule OptimalSystemAgent.Security.CweCatalog do
  @moduledoc """
  Curated CWE catalog for the vulnerability classes OSA detects, with the
  mapping every finding needs to be report-grade: CWE id + name, the OWASP Top
  10 (2021) category, and a typical CVSS v3.1 base vector for that class.

  This is deliberately NOT the full 900-entry MITRE CWE list — it is the subset
  that OSA's whitebox analyzer and manual checklist actually surface, keyed by
  the atom vuln-class those produce (`:sqli`, `:idor`, ...). A finding that
  cannot be mapped to a CWE here is reported as unmapped rather than being
  force-fit, so the gap is visible instead of silently wrong.
  """

  @catalog %{
    sqli: %{
      cwe: "CWE-89",
      name: "SQL Injection",
      owasp: "A03:2021-Injection",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
    },
    rce: %{
      cwe: "CWE-94",
      name: "Code Injection",
      owasp: "A03:2021-Injection",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
    },
    command_injection: %{
      cwe: "CWE-78",
      name: "OS Command Injection",
      owasp: "A03:2021-Injection",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
    },
    xss: %{
      cwe: "CWE-79",
      name: "Cross-site Scripting",
      owasp: "A03:2021-Injection",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N"
    },
    ssti: %{
      cwe: "CWE-1336",
      name: "Server-Side Template Injection",
      owasp: "A03:2021-Injection",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H"
    },
    xxe: %{
      cwe: "CWE-611",
      name: "XML External Entity Reference",
      owasp: "A05:2021-Security Misconfiguration",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N"
    },
    idor: %{
      cwe: "CWE-639",
      name: "Authorization Bypass Through User-Controlled Key",
      owasp: "A01:2021-Broken Access Control",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:L/A:N"
    },
    path_traversal: %{
      cwe: "CWE-22",
      name: "Path Traversal",
      owasp: "A01:2021-Broken Access Control",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N"
    },
    lfi: %{
      cwe: "CWE-98",
      name: "PHP Remote/Local File Inclusion",
      owasp: "A03:2021-Injection",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
    },
    ssrf: %{
      cwe: "CWE-918",
      name: "Server-Side Request Forgery",
      owasp: "A10:2021-SSRF",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:L/A:N"
    },
    deserialization: %{
      cwe: "CWE-502",
      name: "Deserialization of Untrusted Data",
      owasp: "A08:2021-Software and Data Integrity Failures",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
    },
    open_redirect: %{
      cwe: "CWE-601",
      name: "Open Redirect",
      owasp: "A01:2021-Broken Access Control",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:N/A:N"
    },
    csrf: %{
      cwe: "CWE-352",
      name: "Cross-Site Request Forgery",
      owasp: "A01:2021-Broken Access Control",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:N/I:H/A:N"
    },
    auth_bypass: %{
      cwe: "CWE-287",
      name: "Improper Authentication",
      owasp: "A07:2021-Identification and Authentication Failures",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:N"
    },
    privilege_escalation: %{
      cwe: "CWE-269",
      name: "Improper Privilege Management",
      owasp: "A01:2021-Broken Access Control",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H"
    },
    nosql: %{
      cwe: "CWE-943",
      name: "NoSQL Injection",
      owasp: "A03:2021-Injection",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:N"
    },
    prototype_pollution: %{
      cwe: "CWE-1321",
      name: "Prototype Pollution",
      owasp: "A08:2021-Software and Data Integrity Failures",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
    },
    request_smuggling: %{
      cwe: "CWE-444",
      name: "HTTP Request Smuggling",
      owasp: "A05:2021-Security Misconfiguration",
      typical_cvss: "CVSS:3.1/AV:N/AC:H/PR:N/UI:N/S:C/C:H/I:H/A:N"
    },
    weak_crypto: %{
      cwe: "CWE-327",
      name: "Use of a Broken or Risky Cryptographic Algorithm",
      owasp: "A02:2021-Cryptographic Failures",
      typical_cvss: "CVSS:3.1/AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:N/A:N"
    },
    hardcoded_secret: %{
      cwe: "CWE-798",
      name: "Use of Hard-coded Credentials",
      owasp: "A07:2021-Identification and Authentication Failures",
      typical_cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
    }
  }

  @doc "All catalogued vuln-class atoms."
  @spec classes() :: [atom()]
  def classes, do: Map.keys(@catalog)

  @doc "Look up the CWE/OWASP/typical-CVSS entry for a vuln class, or `nil`."
  @spec lookup(atom()) :: map() | nil
  def lookup(class) when is_atom(class), do: Map.get(@catalog, class)
  def lookup(_), do: nil

  @doc "CWE id for a class (e.g. `\"CWE-89\"`), or `nil` when unmapped."
  @spec cwe(atom()) :: String.t() | nil
  def cwe(class), do: with(%{cwe: id} <- lookup(class), do: id)

  @doc "OWASP Top 10 category for a class, or `nil`."
  @spec owasp(atom()) :: String.t() | nil
  def owasp(class), do: with(%{owasp: o} <- lookup(class), do: o)

  @doc "A typical CVSS v3.1 base vector for a class — a starting point a judge refines, or `nil`."
  @spec typical_cvss(atom()) :: String.t() | nil
  def typical_cvss(class), do: with(%{typical_cvss: v} <- lookup(class), do: v)
end
