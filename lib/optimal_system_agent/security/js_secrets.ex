defmodule OptimalSystemAgent.Security.JsSecrets do
  @moduledoc """
  Rip high-signal secrets and internal URLs out of JavaScript bundles.

  Downloaded webpack chunks and source maps
  leak cloud keys, JWTs, and intranet endpoints. Regex only, no network, no
  payloads. Hits are unique on `{kind, value}` and capped at 200.
  """

  @max_hits 200
  @default_max_files 200
  @js_exts MapSet.new(~w(.js .mjs .cjs .map))
  @skip_dirs MapSet.new(~w(node_modules .git))

  @aws_re ~r/\b(AKIA[0-9A-Z]{16})\b/
  @github_re ~r/\b(ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|ghu_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,})\b/
  @slack_re ~r/\b(xox[baprs]-[A-Za-z0-9-]{10,48})\b/
  @google_re ~r/\b(AIza[0-9A-Za-z\-_]{35})\b/
  @stripe_re ~r/\b([rs]k_live_[A-Za-z0-9]{16,})\b/
  @jwt_re ~r/\b(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b/
  @pem_re ~r/-----BEGIN (?:RSA|OPENSSH|EC) PRIVATE KEY-----/
  @bearer_re ~r/Authorization["']?\s*:\s*["']?Bearer\s+([A-Za-z0-9._\-+=\/]+)/i
  @basic_re ~r{(https?://[^/\s:@'"]+:[^/\s:@'"]+@[^/\s"'`]+)}
  @password_re ~r/\b(password|apiKey|api_key|secret|client_secret)\s*[:=]\s*["']([^"']+)["']/i
  @generic_re ~r/\b(access_token|auth_token|secret_key|private_token|oauth_token|refresh_token)\s*[:=]\s*["']([^"']{12,})["']/i
  @fetch_re ~r{(?:(?:window\.)?fetch|axios(?:\.(?:get|post|put|patch|delete|head|options|request))?)\(\s*[`'"](https?://[^`'"]+)[`'"]}i
  @xhr_re ~r{\.open\(\s*[`'"][A-Za-z]+[`'"]\s*,\s*[`'"](https?://[^`'"]+)[`'"]}i

  # ccTLDs are treated as public via length == 2. This list is gTLDs we must
  # not flag as "internal hostname" just because they are not a ccTLD.
  @public_gtlds MapSet.new(~w(
    com net org edu gov mil int info biz app dev ai xyz me tv cc ws
    pro name mobi cloud online site shop store tech blog news live
    space website digital agency studio design media group network
    systems software solutions services health finance legal
    consulting ltd llc inc io
  ))

  @cdn_suffixes ~w(
    jsdelivr.net unpkg.com cloudflare.com cloudfront.net
    fastly.net akamaihd.net akamai.net googleapis.com gstatic.com
    bootstrapcdn.com jquery.com cdnjs.com
  )

  @type kind ::
          :aws_key
          | :github_token
          | :slack_token
          | :google_api
          | :stripe
          | :jwt
          | :private_key
          | :bearer
          | :basic_auth
          | :generic_secret
          | :internal_url
          | :hardcoded_password

  @type hit :: %{
          kind: kind(),
          value: String.t(),
          line: pos_integer(),
          path: String.t() | nil,
          confidence: :high | :medium | :low
        }

  @doc "Parse JavaScript (or any text) and return unique secret hits."
  @spec extract(String.t()) :: {:ok, [hit()]} | {:error, String.t()}
  def extract(source) when is_binary(source) do
    {:ok, source |> scan(nil) |> finalize()}
  end

  def extract(_), do: {:error, "source must be a string"}

  @doc "Read a file then extract/1. Missing file is an error."
  @spec extract_file(String.t()) :: {:ok, [hit()]} | {:error, String.t()}
  def extract_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source |> scan(path) |> finalize()}
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  def extract_file(_), do: {:error, "path must be a string"}

  @doc """
  Walk `**/*.{js,mjs,cjs,map}` under a directory.

  Options: `:max_files` (default 200). Skips `node_modules` and `.git`.
  """
  @spec extract_dir(String.t(), keyword()) :: {:ok, [hit()]} | {:error, String.t()}
  def extract_dir(root, opts \\ [])

  def extract_dir(root, opts) when is_binary(root) and is_list(opts) do
    if File.dir?(root) do
      max_files = Keyword.get(opts, :max_files, @default_max_files)

      hits =
        root
        |> list_js_files(max_files)
        |> Enum.flat_map(fn path ->
          case File.read(path) do
            {:ok, source} -> scan(source, path)
            _ -> []
          end
        end)

      {:ok, finalize(hits)}
    else
      {:error, "not a directory: #{root}"}
    end
  end

  def extract_dir(_, _), do: {:error, "root must be a directory path"}

  @doc "Compact table: kind, path:line, redacted value, confidence."
  @spec render([hit()]) :: String.t()
  def render([]), do: "no js secrets"

  def render(hits) when is_list(hits) do
    rows =
      Enum.map(hits, fn h ->
        loc = "#{h.path || "-"}:#{h.line}"
        "#{h.kind}\t#{loc}\t#{redact(h.value)}\t#{h.confidence}"
      end)

    Enum.join(["kind\tloc\tvalue\tconfidence" | rows], "\n")
  end

  # ── scan ────────────────────────────────────────────────────────────────

  defp scan(source, path) do
    line_hits =
      source
      |> String.split("\n", trim: false)
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} -> detect_line(line, n, path) end)

    line_hits ++ detect_pem(source, path)
  end

  defp detect_line(line, n, path) do
    captures(line, @aws_re, n, path, :aws_key, :high) ++
      captures(line, @github_re, n, path, :github_token, :high) ++
      captures(line, @slack_re, n, path, :slack_token, :high) ++
      captures(line, @google_re, n, path, :google_api, :high) ++
      captures(line, @stripe_re, n, path, :stripe, :high) ++
      captures(line, @jwt_re, n, path, :jwt, :high) ++
      captures(line, @bearer_re, n, path, :bearer, :high) ++
      captures(line, @basic_re, n, path, :basic_auth, :high) ++
      assignment_hits(line, n, path) ++
      internal_url_hits(line, n, path)
  end

  defp captures(line, re, n, path, kind, confidence) do
    re
    |> Regex.scan(line)
    |> Enum.map(fn
      [_, value | _] -> hit(kind, value, n, path, confidence)
      [value] -> hit(kind, value, n, path, confidence)
    end)
  end

  defp assignment_hits(line, n, path) do
    passwords =
      Regex.scan(@password_re, line)
      |> Enum.flat_map(fn
        [_, _key, value] ->
          if placeholder?(value),
            do: [],
            else: [hit(:hardcoded_password, value, n, path, :high)]

        _ ->
          []
      end)

    generics =
      Regex.scan(@generic_re, line)
      |> Enum.flat_map(fn
        [_, _key, value] ->
          if placeholder?(value),
            do: [],
            else: [hit(:generic_secret, value, n, path, :low)]

        _ ->
          []
      end)

    passwords ++ generics
  end

  defp internal_url_hits(line, n, path) do
    urls =
      Regex.scan(@fetch_re, line) ++
        Regex.scan(@xhr_re, line)

    urls
    |> Enum.flat_map(fn
      [_, url] ->
        if usable_url?(url) and looks_internal?(url),
          do: [hit(:internal_url, url, n, path, :medium)],
          else: []

      _ ->
        []
    end)
  end

  defp detect_pem(source, path) do
    @pem_re
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, _len} | _] ->
      take = min(240, byte_size(source) - start)
      value = binary_part(source, start, take)
      hit(:private_key, value, line_at(source, start), path, :high)
    end)
  end

  # ── internal URL heuristic ──────────────────────────────────────────────

  defp usable_url?(url) do
    is_binary(url) and url != "" and not String.contains?(url, "${")
  end

  defp looks_internal?(url) do
    host =
      case URI.parse(url) do
        %URI{host: h} when is_binary(h) and h != "" ->
          h |> String.downcase() |> String.trim_trailing(".")

        _ ->
          nil
      end

    cond do
      is_nil(host) ->
        false

      cdn_host?(host) ->
        false

      host in ["localhost", "127.0.0.1", "0.0.0.0", "::1"] ->
        true

      String.ends_with?(host, ".localhost") ->
        true

      String.ends_with?(host, ".internal") ->
        true

      String.contains?(host, ".internal.") ->
        true

      String.ends_with?(host, ".local") ->
        true

      String.contains?(host, ".local.") ->
        true

      true ->
        case parse_ip(host) do
          {:ok, addr} -> private_addr?(addr)
          :error -> not public_dns_name?(host)
        end
    end
  end

  defp cdn_host?(host) do
    Enum.any?(@cdn_suffixes, fn sfx -> host == sfx or String.ends_with?(host, "." <> sfx) end)
  end

  defp parse_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} -> {:ok, addr}
      _ -> :error
    end
  end

  # RFC1918 10/8, 172.16/12, 192.168/16, plus loopback and link-local.
  defp private_addr?({a, b, _, _})
       when a == 10 or a == 127 or (a == 192 and b == 168) or (a == 169 and b == 254) or
              (a == 172 and b in 16..31),
       do: true

  defp private_addr?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_addr?(_), do: false

  defp public_dns_name?(host) do
    parts = String.split(host, ".")
    tld = List.last(parts)

    cond do
      length(parts) < 2 -> false
      String.length(tld) == 2 -> true
      MapSet.member?(@public_gtlds, tld) -> true
      true -> false
    end
  end

  defp placeholder?(value) do
    v = String.trim(value)
    v == "" or v in ["null", "undefined", "true", "false"] or Regex.match?(~r/^[\s*xX]+$/, v)
  end

  # ── files ───────────────────────────────────────────────────────────────

  defp list_js_files(root, max) do
    walk_js(root, [], max) |> Enum.reverse()
  end

  defp walk_js(_dir, acc, max) when length(acc) >= max, do: acc

  defp walk_js(dir, acc, max) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce(acc, fn name, a ->
          if length(a) >= max do
            a
          else
            path = Path.join(dir, name)

            cond do
              MapSet.member?(@skip_dirs, name) ->
                a

              File.dir?(path) ->
                walk_js(path, a, max)

              File.regular?(path) and js_file?(name) ->
                [path | a]

              true ->
                a
            end
          end
        end)

      _ ->
        acc
    end
  end

  defp js_file?(name) do
    MapSet.member?(@js_exts, String.downcase(Path.extname(name)))
  end

  defp finalize(hits) do
    hits
    |> Enum.uniq_by(&{&1.kind, &1.value})
    |> Enum.take(@max_hits)
  end

  defp hit(kind, value, line, path, confidence) do
    %{kind: kind, value: value, line: line, path: path, confidence: confidence}
  end

  defp line_at(_source, offset) when offset <= 0, do: 1

  defp line_at(source, offset) do
    prefix = binary_part(source, 0, min(offset, byte_size(source)))
    length(:binary.matches(prefix, "\n")) + 1
  end

  defp redact(value) when is_binary(value) do
    if String.length(value) > 12 do
      String.slice(value, 0, 12) <> "..."
    else
      String.slice(value, 0, min(4, String.length(value))) <> "..."
    end
  end
end
