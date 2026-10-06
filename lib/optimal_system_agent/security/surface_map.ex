defmodule OptimalSystemAgent.Security.SurfaceMap do
  @moduledoc """
  Parses already-captured recon text into owned CIDRs, vhost candidates, and live hosts.

  This module does not scan, probe, send packets, or talk to the network.
  It only reads WHOIS/route blobs, name lists, and httpx-style result text.
  """

  import Bitwise

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

  @default_wordlist ~w(www api admin staging dev app mail intranet vpn portal git grafana)

  @source_rank %{whois: 0, route: 1, netrange: 2}
  @kind_rank %{san: 0, given: 1, prefix: 2}

  @cidr_re ~r/\b(\d{1,3}(?:\.\d{1,3}){3}\/\d{1,2})\b/
  @netrange_re ~r/(\d{1,3}(?:\.\d{1,3}){3})\s*[-\x{2013}\x{2014}]\s*(\d{1,3}(?:\.\d{1,3}){3})/u
  @org_re ~r/^(orgname|org-name)\s*:\s*(.+)$/i
  @text_probe_re ~r/^(\S+)\s+\[(\d{3})\](.*)$/

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Extract unique owned CIDRs from WHOIS or route text.

  Understands `CIDR:`, `route:`, and exact-prefix `NetRange:` / `inetnum:` lines.
  Attaches `OrgName` / `org-name` when present. Junk is ignored.
  """
  @spec cidrs_from_whois(String.t()) :: {:ok, [cidr()]} | {:error, String.t()}
  def cidrs_from_whois(blob) when is_binary(blob) do
    {entries, orgs} =
      blob
      |> split_lines()
      |> Enum.reduce({[], []}, &scan_whois_line/2)

    fallback_org = List.first(Enum.reverse(orgs))

    cidrs =
      entries
      |> Enum.reverse()
      |> Enum.map(fn rec -> %{rec | org: rec.org || fallback_org} end)
      |> uniq_cidrs()

    {:ok, cidrs}
  end

  def cidrs_from_whois(_), do: {:error, "whois blob must be a string"}

  @doc """
  Derive unique vhost candidates for a parent domain.

  Options:
    * `:domain` (required) - parent domain, e.g. `"example.com"`
    * `:names` - extra hosts from subfinder or cert SANs
    * `:wordlist` - extra prefixes, unioned with a small built-in list
  """
  @spec vhost_candidates(keyword()) :: {:ok, [vhost()]} | {:error, String.t()}
  def vhost_candidates(opts) when is_list(opts) do
    case normalize_domain(Keyword.get(opts, :domain)) do
      {:ok, domain} ->
        names = Keyword.get(opts, :names, [])
        names = if is_list(names), do: names, else: []

        prefixes =
          opts
          |> Keyword.get(:wordlist)
          |> build_wordlist()
          |> Enum.flat_map(&prefix_vhost(&1, domain))

        given = Enum.flat_map(names, &name_vhost(&1, domain))
        {:ok, uniq_vhosts(prefixes ++ given)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def vhost_candidates(_), do: {:error, "domain is required"}

  @doc """
  Parse already-run httpx output (JSONL or `host [status] [title]` lines).

  Does not probe. Lines that are not JSON objects or probe rows are skipped.
  """
  @spec ingest_httpx(String.t()) :: {:ok, [host()]} | {:error, String.t()}
  def ingest_httpx(blob) when is_binary(blob) do
    hosts =
      blob
      |> split_lines()
      |> Enum.flat_map(&parse_httpx_line/1)
      |> uniq_hosts()

    {:ok, hosts}
  end

  def ingest_httpx(_), do: {:error, "httpx output must be a string"}

  @doc """
  True when `ip` is IPv4 and falls inside one of the CIDR strings.

  Invalid IPs return false. IPv6 is treated as out of scope.
  """
  @spec in_owned_cidr?(String.t(), [String.t()]) :: boolean()
  def in_owned_cidr?(ip, cidrs) when is_binary(ip) and is_list(cidrs) do
    case parse_ipv4(ip) do
      {:ok, ip_int} -> Enum.any?(cidrs, &ip_in_cidr?(ip_int, &1))
      :error -> false
    end
  end

  def in_owned_cidr?(_, _), do: false

  @doc "Render a compact recon map from `%{cidrs: ..., vhosts: ..., live: ...}`."
  @spec render(map()) :: String.t()
  def render(map) when is_map(map) do
    cidrs = map_list(map, :cidrs)
    vhosts = map_list(map, :vhosts)
    live = map_list(map, :live)

    [
      "surface map",
      render_cidrs(cidrs),
      render_vhosts(vhosts),
      render_live(live)
    ]
    |> Enum.join("\n")
  end

  def render(_), do: "surface map"

  # ── WHOIS / route parsing ─────────────────────────────────────────────────

  defp scan_whois_line(line, {entries, orgs}) do
    line = String.trim(line)

    cond do
      org = match_org(line) ->
        {entries, [org | orgs]}

      recs = match_cidr_line(line, current_org(orgs)) ->
        {Enum.reduce(recs, entries, fn rec, acc -> [rec | acc] end), orgs}

      true ->
        {entries, orgs}
    end
  end

  defp current_org([org | _]), do: org
  defp current_org([]), do: nil

  defp match_org(line) do
    case Regex.run(@org_re, line) do
      [_, _key, name] ->
        name = String.trim(name)
        if name == "", do: nil, else: name

      _ ->
        nil
    end
  end

  defp match_cidr_line(line, org) do
    cond do
      cidr_label?(line, "cidr") -> extract_labeled_cidrs(line, :whois, org)
      cidr_label?(line, "route") -> extract_labeled_cidrs(line, :route, org)
      netrange_label?(line) -> extract_netrange(line, org)
      true -> nil
    end
  end

  defp cidr_label?(line, label) do
    Regex.match?(~r/^#{label}\s*:/i, line) and not Regex.match?(~r/^#{label}\d/i, line)
  end

  defp netrange_label?(line), do: Regex.match?(~r/^(netrange|inetnum)\s*:/i, line)

  defp extract_labeled_cidrs(line, source, org) do
    cidrs =
      @cidr_re
      |> Regex.scan(line, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(fn raw ->
        case normalize_cidr(raw) do
          {:ok, cidr} -> [%{cidr: cidr, source: source, org: org}]
          :error -> []
        end
      end)

    if cidrs == [], do: nil, else: cidrs
  end

  defp extract_netrange(line, org) do
    case Regex.run(@netrange_re, line) do
      [_, start_ip, end_ip] ->
        case netrange_to_cidr(start_ip, end_ip) do
          {:ok, cidr} -> [%{cidr: cidr, source: :netrange, org: org}]
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp netrange_to_cidr(start_ip, end_ip) do
    with {:ok, start_int} <- parse_ipv4(start_ip),
         {:ok, end_int} <- parse_ipv4(end_ip),
         true <- end_int >= start_int,
         size = end_int - start_int + 1,
         true <- power_of_two?(size) do
      prefix = 32 - log2_pow2(size)
      hostmask = prefix_hostmask(prefix)

      if (start_int &&& hostmask) == 0 do
        {:ok, format_ipv4(start_int) <> "/" <> Integer.to_string(prefix)}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp uniq_cidrs(cidrs) do
    {order, map} =
      Enum.reduce(cidrs, {[], %{}}, fn rec, {order, map} ->
        case Map.get(map, rec.cidr) do
          nil ->
            {[rec.cidr | order], Map.put(map, rec.cidr, rec)}

          old ->
            {order, Map.put(map, rec.cidr, merge_cidr(old, rec))}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(map, &1))
  end

  defp merge_cidr(old, new) do
    source =
      if Map.get(@source_rank, new.source, 9) < Map.get(@source_rank, old.source, 9) do
        new.source
      else
        old.source
      end

    %{cidr: old.cidr, source: source, org: old.org || new.org}
  end

  # ── Vhost candidates ──────────────────────────────────────────────────────

  defp normalize_domain(domain) when is_binary(domain) do
    domain =
      domain
      |> String.trim()
      |> String.downcase()
      |> String.trim_trailing(".")

    domain =
      case host_from_ref(domain) do
        nil -> domain
        host -> host
      end

    if domain == "" or String.contains?(domain, " ") do
      {:error, "domain is required"}
    else
      {:ok, domain}
    end
  end

  defp normalize_domain(_), do: {:error, "domain is required"}

  defp build_wordlist(nil), do: @default_wordlist

  defp build_wordlist(extra) when is_list(extra) do
    Enum.uniq(@default_wordlist ++ Enum.map(extra, &to_string/1))
  end

  defp build_wordlist(_), do: @default_wordlist

  defp prefix_vhost(prefix, domain) do
    label =
      prefix
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.trim_trailing(".")

    if label == "" or String.contains?(label, [" ", "/", ":"]) do
      []
    else
      [%{host: label <> "." <> domain, kind: :prefix, parent: domain}]
    end
  end

  defp name_vhost(name, domain) when is_binary(name) do
    trimmed = String.trim(name)
    wildcard? = String.contains?(trimmed, "*")

    host =
      trimmed
      |> String.replace("*", "")
      |> host_from_ref()
      |> case do
        nil -> nil
        host -> String.trim_leading(host, ".")
      end

    host =
      cond do
        host in [nil, ""] -> nil
        String.contains?(host, ".") -> host
        true -> host <> "." <> domain
      end

    cond do
      host in [nil, ""] -> []
      not in_scope?(host, domain) -> []
      wildcard? -> [%{host: host, kind: :san, parent: domain}]
      true -> [%{host: host, kind: :given, parent: domain}]
    end
  end

  defp name_vhost(_, _), do: []

  defp in_scope?(host, domain), do: host == domain or String.ends_with?(host, "." <> domain)

  defp uniq_vhosts(vhosts) do
    {order, map} =
      Enum.reduce(vhosts, {[], %{}}, fn rec, {order, map} ->
        case Map.get(map, rec.host) do
          nil ->
            {[rec.host | order], Map.put(map, rec.host, rec)}

          old ->
            preferred =
              if Map.get(@kind_rank, rec.kind, 9) < Map.get(@kind_rank, old.kind, 9),
                do: rec,
                else: old

            {order, Map.put(map, rec.host, preferred)}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(map, &1))
  end

  # ── httpx ingest ──────────────────────────────────────────────────────────

  defp parse_httpx_line(line) do
    line = String.trim(line)

    cond do
      line == "" -> []
      String.starts_with?(line, "{") -> parse_httpx_json(line)
      rec = parse_httpx_text(line) -> [rec]
      true -> []
    end
  end

  defp parse_httpx_json(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) ->
        case host_record_from_json(map) do
          nil -> []
          rec -> [rec]
        end

      {:ok, list} when is_list(list) ->
        Enum.flat_map(list, fn
          item when is_map(item) ->
            case host_record_from_json(item) do
              nil -> []
              rec -> [rec]
            end

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp host_record_from_json(map) do
    raw = json_string(map, ["url", "input", "host"])

    host =
      case raw do
        nil -> nil
        ref -> host_from_ref(ref)
      end

    if host in [nil, ""] do
      nil
    else
      %{
        host: host,
        status: json_status(map),
        title: json_string(map, ["title"]),
        vhost: json_string(map, ["host-header", "host_header", "vhost"])
      }
    end
  end

  defp json_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        val when is_binary(val) ->
          val = String.trim(val)
          if val == "", do: nil, else: val

        val when is_integer(val) ->
          Integer.to_string(val)

        _ ->
          nil
      end
    end)
  end

  defp json_status(map) do
    Enum.find_value(["status-code", "status_code", "status"], fn key ->
      case Map.get(map, key) do
        n when is_integer(n) and n >= 0 and n <= 599 ->
          n

        s when is_binary(s) ->
          case Integer.parse(String.trim(s)) do
            {n, ""} when n >= 0 and n <= 599 -> n
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp parse_httpx_text(line) do
    case Regex.run(@text_probe_re, line) do
      [_, ref, status, rest] ->
        case host_from_ref(ref) do
          host when is_binary(host) and host != "" ->
            %{
              host: host,
              status: String.to_integer(status),
              title: text_title(rest),
              vhost: nil
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp text_title(rest) do
    titles =
      ~r/\[([^\]]*)\]/
      |> Regex.scan(rest, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    List.last(titles)
  end

  defp uniq_hosts(hosts) do
    {order, map} =
      Enum.reduce(hosts, {[], %{}}, fn rec, {order, map} ->
        case Map.get(map, rec.host) do
          nil ->
            {[rec.host | order], Map.put(map, rec.host, rec)}

          old ->
            {order, Map.put(map, rec.host, merge_host(old, rec))}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(map, &1))
  end

  defp merge_host(old, new) do
    %{
      host: old.host,
      status: old.status || new.status,
      title: old.title || new.title,
      vhost: old.vhost || new.vhost
    }
  end

  # ── CIDR membership ───────────────────────────────────────────────────────

  defp ip_in_cidr?(ip_int, cidr) when is_binary(cidr) do
    case parse_cidr_parts(cidr) do
      {:ok, _net_int, 0} ->
        true

      {:ok, net_int, prefix} ->
        shift = 32 - prefix
        bsr(ip_int, shift) == bsr(net_int, shift)

      :error ->
        false
    end
  end

  defp ip_in_cidr?(_, _), do: false

  defp parse_cidr_parts(cidr) do
    case String.split(String.trim(cidr), "/", parts: 2) do
      [ip, prefix_s] ->
        with {:ok, ip_int} <- parse_ipv4(ip),
             {prefix, ""} <- Integer.parse(prefix_s),
             true <- prefix in 0..32 do
          {:ok, ip_int, prefix}
        else
          _ -> :error
        end

      [ip] ->
        case parse_ipv4(ip) do
          {:ok, ip_int} -> {:ok, ip_int, 32}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp normalize_cidr(raw) do
    case parse_cidr_parts(raw) do
      {:ok, ip_int, prefix} ->
        net = apply_prefix(ip_int, prefix)
        {:ok, format_ipv4(net) <> "/" <> Integer.to_string(prefix)}

      :error ->
        :error
    end
  end

  defp apply_prefix(_ip, 0), do: 0
  defp apply_prefix(ip, 32), do: ip

  defp apply_prefix(ip, prefix) when prefix in 1..31 do
    shift = 32 - prefix
    bsl(bsr(ip, shift), shift)
  end

  defp prefix_hostmask(0), do: 0xFFFFFFFF
  defp prefix_hostmask(32), do: 0
  defp prefix_hostmask(prefix) when prefix in 1..31, do: bsl(1, 32 - prefix) - 1

  defp power_of_two?(n) when is_integer(n) and n > 0, do: (n &&& n - 1) == 0
  defp power_of_two?(_), do: false

  defp log2_pow2(n), do: log2_pow2(n, 0)
  defp log2_pow2(1, acc), do: acc
  defp log2_pow2(n, acc) when n > 1, do: log2_pow2(bsr(n, 1), acc + 1)

  defp parse_ipv4(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, {a, b, c, d}} -> {:ok, ipv4_to_int({a, b, c, d})}
      _ -> :error
    end
  end

  defp parse_ipv4(_), do: :error

  defp ipv4_to_int({a, b, c, d}) do
    bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
  end

  defp format_ipv4(int) do
    a = bsr(int, 24) &&& 0xFF
    b = bsr(int, 16) &&& 0xFF
    c = bsr(int, 8) &&& 0xFF
    d = int &&& 0xFF
    Enum.join([a, b, c, d], ".")
  end

  # ── Shared host / line helpers ────────────────────────────────────────────

  defp split_lines(blob) do
    blob
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
  end

  defp host_from_ref(ref) when is_binary(ref) do
    ref =
      ref
      |> String.trim()
      |> String.downcase()
      |> String.trim_trailing(".")

    host =
      if String.contains?(ref, "://") do
        case URI.parse(ref) do
          %URI{host: host} when is_binary(host) and host != "" -> host
          _ -> nil
        end
      else
        ref
        |> String.split("/", parts: 2)
        |> hd()
        |> strip_port()
      end

    case host do
      host when is_binary(host) and host != "" -> String.trim_trailing(host, ".")
      _ -> nil
    end
  end

  defp host_from_ref(_), do: nil

  defp strip_port(host) do
    case Regex.run(~r/^(.+):(\d+)$/, host) do
      [_, name, _port] -> name
      _ -> host
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────

  defp map_list(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || []
  end

  defp render_cidrs([]), do: "cidrs: none"

  defp render_cidrs(cidrs) do
    rows =
      cidrs
      |> Enum.map(&format_cidr_row/1)
      |> Enum.reject(&is_nil/1)

    Enum.join(["cidrs (#{length(rows)})" | rows], "\n")
  end

  defp format_cidr_row(%{cidr: cidr} = rec) do
    src = rec |> Map.get(:source) |> source_label()
    org = Map.get(rec, :org)
    "  #{cidr}  #{src}" <> if(is_binary(org) and org != "", do: "  #{org}", else: "")
  end

  defp format_cidr_row(cidr) when is_binary(cidr), do: "  #{cidr}"
  defp format_cidr_row(_), do: nil

  defp render_vhosts([]), do: "vhosts: none"

  defp render_vhosts(vhosts) do
    rows =
      vhosts
      |> Enum.map(&format_vhost_row/1)
      |> Enum.reject(&is_nil/1)

    Enum.join(["vhosts (#{length(rows)})" | rows], "\n")
  end

  defp format_vhost_row(%{host: host} = rec) do
    kind = rec |> Map.get(:kind) |> kind_label()
    parent = Map.get(rec, :parent)
    "  #{host}  #{kind}" <> if(is_binary(parent) and parent != "", do: "  #{parent}", else: "")
  end

  defp format_vhost_row(host) when is_binary(host), do: "  #{host}"
  defp format_vhost_row(_), do: nil

  defp render_live([]), do: "live: none"

  defp render_live(hosts) do
    rows =
      hosts
      |> Enum.map(&format_live_row/1)
      |> Enum.reject(&is_nil/1)

    Enum.join(["live (#{length(rows)})" | rows], "\n")
  end

  defp format_live_row(%{host: host} = rec) do
    status = Map.get(rec, :status)
    title = Map.get(rec, :title)
    vhost = Map.get(rec, :vhost)

    [
      "  #{host}",
      if(is_integer(status), do: Integer.to_string(status), else: nil),
      if(is_binary(title) and title != "", do: title, else: nil),
      if(is_binary(vhost) and vhost != "", do: "vhost=#{vhost}", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("  ")
  end

  defp format_live_row(host) when is_binary(host), do: "  #{host}"
  defp format_live_row(_), do: nil

  defp source_label(:whois), do: "whois"
  defp source_label(:route), do: "route"
  defp source_label(:netrange), do: "netrange"
  defp source_label(_), do: "-"

  defp kind_label(:prefix), do: "prefix"
  defp kind_label(:san), do: "san"
  defp kind_label(:given), do: "given"
  defp kind_label(_), do: "-"
end
