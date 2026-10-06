# Wire SurfaceMap into SecurityIntel

Parse-only recon mapper.
No network, no probes, no packets.
Parent should add actions in `lib/optimal_system_agent/security/security_intel.ex`.
Do not change prompts, skills, or agent role files for this wiring.

Module: `OptimalSystemAgent.Security.SurfaceMap`
Tests: `mix test test/security/surface_map_test.exs --exclude integration`

## Hard constraints

SurfaceMap never scans the internet.
It never runs whois, httpx, subfinder, or vhost brute.
It never emits C2, implants, exploit payloads, or live packets.
SecurityIntel must keep that boundary.
Pass already-captured tool output in.
Get candidates and a rendered map out.

## API

```elixir
alias OptimalSystemAgent.Security.SurfaceMap

@type cidr :: %{
  cidr: String.t(),
  source: :whois | :route | :netrange,
  org: String.t() | nil
}

@type vhost :: %{
  host: String.t(),
  kind: :prefix | :san | :given,
  parent: String.t()
}

@type host :: %{
  host: String.t(),
  status: integer() | nil,
  title: String.t() | nil,
  vhost: String.t() | nil
}

@spec cidrs_from_whois(String.t()) :: {:ok, [cidr()]} | {:error, String.t()}
@spec vhost_candidates(keyword()) :: {:ok, [vhost()]} | {:error, String.t()}
@spec ingest_httpx(String.t()) :: {:ok, [host()]} | {:error, String.t()}
@spec in_owned_cidr?(String.t(), [String.t()]) :: boolean()
@spec render(map()) :: String.t()
```

### cidrs_from_whois/1

Input: WHOIS or route text captured by the operator (ARIN/RIPE/RADB paste).

Parses labeled lines only:

- `CIDR:` -> `%{source: :whois}`
- `route:` -> `%{source: :route}`
- `NetRange:` / `inetnum:` -> CIDR when the range is an exact prefix (`192.0.2.0 - 192.0.2.255` -> `192.0.2.0/24`)

Attaches `OrgName` / `org-name` when present, including org-after-range ARIN order.
Duplicates collapse.
Explicit `CIDR:` wins over `route:` over `NetRange:`.
Empty or junk returns `{:ok, []}`.
Non-string returns `{:error, _}`.

### vhost_candidates/1

Options:

- `:domain` (required) e.g. `"example.com"`
- `:names` extra hosts from subfinder / cert SANs
- `:wordlist` extra prefixes, unioned with `~w(www api admin staging dev app mail intranet vpn portal git grafana)`

Returns unique `%{host, kind, parent}`:

- `:prefix` from the wordlist
- `:given` from `:names`
- `:san` from wildcard names (`*.example.com`)

Names are lowercased and deduped.
Out-of-scope names (other parent domains) are dropped.
Missing `:domain` returns `{:error, reason}` with `"domain"` in the message.

### ingest_httpx/1

Input: already-run httpx output, not a probe.

Accepts JSONL objects with `url` / `input` / `host` / `status-code` / `title` / `webserver` / `host-header`.
Also accepts text rows like `admin.example.com [200] [Admin]`.
Host is taken from the URL hostname, not the resolved IP.
`host-header` / `vhost` populate `:vhost`.
Junk lines are skipped.
Empty input returns `{:ok, []}`.

### in_owned_cidr?/2

IPv4 only.
Uses `:inet.parse_address` plus a bitmask.
Invalid IP -> `false`.

```elixir
SurfaceMap.in_owned_cidr?("198.51.100.20", ["198.51.100.0/24"])
# true
SurfaceMap.in_owned_cidr?("198.51.101.1", ["198.51.100.0/24"])
# false
```

### render/1

```elixir
SurfaceMap.render(%{cidrs: cidrs, vhosts: vhosts, live: live})
```

Compact recon map string for intel context / reports.

## Actions parent should add to security_intel.ex

Keep the existing SecurityIntel action table.
Add these as parse/derive actions only.
Do not introduce a scanner.

### 1. `:owned_cidrs`

Args: `%{text: whois_or_route_blob}` (also accept `:blob` / `"text"`).

```elixir
def action(:owned_cidrs, %{text: text}) when is_binary(text) do
  SurfaceMap.cidrs_from_whois(text)
end
```

Error if text is missing.

### 2. `:vhost_candidates`

Args: `%{domain: domain, names: list, wordlist: list}`.

```elixir
def action(:vhost_candidates, args) do
  SurfaceMap.vhost_candidates(
    domain: Map.get(args, :domain) || Map.get(args, "domain"),
    names: Map.get(args, :names) || Map.get(args, "names") || [],
    wordlist: Map.get(args, :wordlist) || Map.get(args, "wordlist")
  )
end
```

`:names` should be filled from ReconIngest (subfinder / SAN lists) when that module is wired.
Do not generate names by querying CT logs here.

### 3. `:ingest_httpx`

Args: `%{text: httpx_output}`.

```elixir
def action(:ingest_httpx, %{text: text}) when is_binary(text) do
  SurfaceMap.ingest_httpx(text)
end
```

The operator or a later tool runner captures httpx JSONL.
SecurityIntel only parses it.

### 4. `:in_owned_cidr`

Args: `%{ip: ip, cidrs: [String.t()]}`.

```elixir
def action(:in_owned_cidr, %{ip: ip, cidrs: cidrs}) do
  {:ok, SurfaceMap.in_owned_cidr?(ip, cidrs)}
end
```

Use this to tag live httpx rows whose resolved IP sits in owned space.
The resolved IP is httpx `host` when the parent still has the raw JSON.

### 5. `:render_surface`

Args: `%{cidrs: list, vhosts: list, live: list}`.

```elixir
def action(:render_surface, args) when is_map(args) do
  {:ok, SurfaceMap.render(args)}
end
```

### 6. `:build_surface` (composite, recommended)

Single intel action that builds the recon map from captured artifacts.

Args:

```elixir
%{
  domain: "example.com",
  whois: whois_blob,          # optional
  names: ["Foo.EXAMPLE.com"], # optional, subfinder / SANs
  wordlist: ["staging"],      # optional extra prefixes
  httpx: httpx_blob           # optional already-run output
}
```

Suggested body:

```elixir
def action(:build_surface, args) do
  domain = Map.get(args, :domain) || Map.get(args, "domain")
  whois = Map.get(args, :whois) || Map.get(args, "whois") || ""
  names = Map.get(args, :names) || Map.get(args, "names") || []
  wordlist = Map.get(args, :wordlist) || Map.get(args, "wordlist")
  httpx = Map.get(args, :httpx) || Map.get(args, "httpx") || ""

  with {:ok, cidrs} <- SurfaceMap.cidrs_from_whois(whois),
       {:ok, vhosts} <-
         SurfaceMap.vhost_candidates(domain: domain, names: names, wordlist: wordlist),
       {:ok, live} <- SurfaceMap.ingest_httpx(httpx) do
    map = %{cidrs: cidrs, vhosts: vhosts, live: live}
    {:ok, Map.put(map, :rendered, SurfaceMap.render(map))}
  end
end
```

Return both structured maps and `:rendered`.
The parent can store records and inject the compact string into the agent context.

## Suggested SecurityIntel dispatch

```elixir
@surface_actions ~w(
  owned_cidrs
  vhost_candidates
  ingest_httpx
  in_owned_cidr
  render_surface
  build_surface
)a

# in the existing action router:
# :owned_cidrs       -> SurfaceMap.cidrs_from_whois/1
# :vhost_candidates  -> SurfaceMap.vhost_candidates/1
# :ingest_httpx      -> SurfaceMap.ingest_httpx/1
# :in_owned_cidr     -> SurfaceMap.in_owned_cidr?/2
# :render_surface    -> SurfaceMap.render/1
# :build_surface     -> compose the five calls above
```

If ReconIngest exists or lands next, pipe its parsed blobs into these actions.
Do not re-parse WHOIS / httpx inside SecurityIntel.

## What not to add

Do not add a live whois client.
Do not add httpx / vhost brute / masscan / nmap execution here.
Do not add C2, implant, or payload helpers.
Do not mark hosts in-scope just because a vhost candidate exists.
Scope IPs with `in_owned_cidr?/2`.
Scope hostnames with the parent domain.

## Verify

```
mix test test/security/surface_map_test.exs --exclude integration
```
