defmodule OptimalSystemAgent.Tools.Builtins.WebFetch.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `web_fetch`.

  Behaviour split:
    * `validate/2`           — type checks input shape (cheap, no I/O)
    * `check_permissions/2`  — URL scheme + DNS rebinding guard
    * `execute/2`            — HTTP fetch with redirect following

  All logic moved verbatim from the original `web_fetch.ex`. No semantic
  changes — just relocation into the validate / check_permissions / execute
  split required by the structured layout.
  """

  alias OptimalSystemAgent.Tools.Builtins.WebFetch.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"url" => url} = input, _ctx) when is_binary(url),
    do: {:ok, input}

  def validate(%{"url" => _}, _ctx),
    do: {:error, "url must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: url", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"url" => url} = input, _ctx) do
    case validate_url(url) do
      :ok -> {:allow, input}
      {:error, reason} -> {:deny, "Access denied: #{reason}"}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"url" => url} = input, _ctx) do
    max_length = input["max_length"] || Constants.default_max_length()
    follow_redirects(url, Constants.max_redirects(), max_length)
  end

  # ── Private: URL validation ───────────────────────────────────────────

  defp validate_url(url) do
    uri = URI.parse(url)

    case uri.scheme do
      "https" ->
        check_host_not_private(uri.host || "")

      "http" ->
        host = uri.host || ""

        if host == "localhost" or String.starts_with?(host, "127.") or host == "::1" do
          :ok
        else
          {:error, "Only HTTPS URLs are allowed (got http://#{host})"}
        end

      other ->
        {:error, "Unsupported URL scheme: #{other}. Only https:// is allowed."}
    end
  end

  # Resolve the hostname and reject if any returned address is private/loopback/link-local.
  # Guards against DNS rebinding as well as direct private-IP URLs.
  defp check_host_not_private(""), do: {:error, "URL is missing a host"}

  defp check_host_not_private(host) do
    charlist = String.to_charlist(host)

    addrs =
      case getaddrs(charlist, :inet) do
        {:ok, v4} -> v4
        _ -> []
      end ++
        case getaddrs(charlist, :inet6) do
          {:ok, v6} -> v6
          _ -> []
        end

    cond do
      addrs == [] ->
        {:error, "Cannot resolve host: #{host}"}

      Enum.any?(addrs, &private_ip?/1) ->
        {:error, "Requests to private/internal IP addresses are not allowed (host: #{host})"}

      true ->
        :ok
    end
  end

  # `:inet.getaddrs/2`, with a 2-arity override under
  # `config :optimal_system_agent, :web_fetch_resolver` that must return the
  # same `{:ok, [:inet.ip_address()]} | {:error, term()}` contract.
  #
  # This exists so the permission tests can pin "a public https host is
  # allowed" without a live DNS server: resolving a real name from a unit test
  # made that assertion fail intermittently under a full-suite run (the
  # resolver, not the guard, was what gave out — `{:deny, "Cannot resolve
  # host: …"}`). Unset in production, so the real resolver — and therefore the
  # DNS-rebinding protection this function exists for — is unchanged.
  defp getaddrs(charlist, family) do
    case Application.get_env(:optimal_system_agent, :web_fetch_resolver) do
      fun when is_function(fun, 2) -> fun.(charlist, family)
      _ -> :inet.getaddrs(charlist, family)
    end
  end

  # IPv4 private ranges:
  #   127.0.0.0/8      loopback
  #   10.0.0.0/8       private
  #   172.16.0.0/12    private
  #   192.168.0.0/16   private
  #   169.254.0.0/16   link-local (AWS IMDS lives here)
  #
  # IPv6:
  #   ::1              loopback
  #   fe80::/10        link-local
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  defp private_ip?(_), do: false

  # ── Private: HTTP fetch with redirect following ───────────────────────

  defp follow_redirects(_url, remaining, _max_length) when remaining < 0 do
    {:error, "Too many redirects"}
  end

  defp follow_redirects(url, remaining, max_length) do
    response =
      Req.get(url,
        receive_timeout: 30_000,
        redirect: false,
        headers: [
          {"user-agent", Constants.user_agent()},
          {"accept", Constants.accept()},
          {"accept-language", "en-US,en;q=0.9"}
        ]
      )

    case response do
      {:ok, %Req.Response{status: status, headers: headers}}
      when status in [301, 302, 303, 307, 308] ->
        case get_location_header(headers) do
          nil ->
            {:error, "Redirect response (HTTP #{status}) missing Location header"}

          location ->
            # A Location may be relative ("/docs/index.html"); resolve it
            # against the URL we just requested before validating.
            redirect_url = url |> URI.merge(location) |> URI.to_string()

            case validate_url(redirect_url) do
              {:error, reason} ->
                {:error, "Blocked redirect to #{redirect_url}: #{reason}"}

              :ok ->
                follow_redirects(redirect_url, remaining - 1, max_length)
            end
        end

      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        content_type = extract_content_type(headers)
        formatted = format_body(body, content_type, max_length)

        case content_failure(formatted, status, url, content_type) do
          nil -> {:ok, "#{url}\nHTTP #{status} #{content_type}\n---\n#{formatted}"}
          reason -> {:error, reason}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, http_status_error(status, url)}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Network error fetching #{url}: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Error fetching #{url}: #{inspect(reason)}"}
    end
  end

  # ── Private: failure classification ───────────────────────────────────

  # An error status is never content. Name the status AND why it happened so
  # the model can pick a different source instead of hallucinating from an
  # error page.
  defp http_status_error(403, url),
    do:
      "HTTP 403 Forbidden fetching #{url} — the server refused the request " <>
        "(bot protection or auth required). No content was retrieved. Try a different source."

  defp http_status_error(401, url),
    do:
      "HTTP 401 Unauthorized fetching #{url} — this URL requires authentication. No content was retrieved."

  defp http_status_error(404, url),
    do:
      "HTTP 404 Not Found fetching #{url} — no content was retrieved. Check the URL or try a different source."

  defp http_status_error(429, url),
    do:
      "HTTP 429 Too Many Requests fetching #{url} — rate limited by the server. " <>
        "No content was retrieved. Wait or try a different source."

  defp http_status_error(status, url) when status in 500..599,
    do: "HTTP #{status} fetching #{url} — the server failed. No content was retrieved."

  defp http_status_error(status, url),
    do: "HTTP #{status} fetching #{url} — no content was retrieved."

  # Markers that identify a challenge/interstitial page served with a 200.
  @block_markers [
    "just a moment",
    "checking your browser",
    "attention required",
    "verify you are human",
    "are you a robot",
    "unusual traffic",
    "access to this page has been denied",
    "enable javascript and cookies"
  ]

  # A 2xx whose body carries no usable text is a FAILURE, not content. Returns
  # nil when the body is fine, otherwise the model-facing reason string.
  defp content_failure(formatted, status, url, content_type) do
    trimmed = String.trim(formatted)
    len = String.length(trimmed)
    down = trimmed |> String.slice(0, 600) |> String.downcase()

    cond do
      len == 0 ->
        "HTTP #{status} fetching #{url} returned an EMPTY body (content-type: #{content_type}). " <>
          "No content was retrieved — likely a redirect stub or a bot-block. Try a different source."

      len < Constants.min_content_chars() ->
        "HTTP #{status} fetching #{url} returned only #{len} characters of text " <>
          "(content-type: #{content_type}) — that is a bot-block, a JavaScript-only shell, " <>
          "or a redirect stub, not the page content. Try a different source. Body: #{inspect(trimmed)}"

      len < 2_000 and String.contains?(down, @block_markers) ->
        "HTTP #{status} fetching #{url} returned a bot-protection challenge page, not content. " <>
          "Try a different source. Body starts: #{inspect(String.slice(trimmed, 0, 160))}"

      true ->
        nil
    end
  end

  # ── Private: header access ────────────────────────────────────────────

  # Req normalises response headers to a MAP of lowercase name => LIST of
  # values (`%{"content-type" => ["text/html; charset=utf-8"]}`). The previous
  # `Map.get/2` handed that LIST straight to `String.contains?/2`, which has no
  # clause for a list — so EVERY 2xx fetch raised `FunctionClauseError` and the
  # model received a 78-byte
  # `"Error: Tool execution error: no function clause matching in String.contains?/2"`
  # rendered as a successful "Received 78B" cell. Normalise to a binary here.
  defp header_value(headers, name) when is_map(headers) do
    headers |> Map.get(name) |> first_header_value()
  end

  defp header_value(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> first_header_value(value)
      nil -> nil
    end
  end

  defp header_value(_headers, _name), do: nil

  defp first_header_value([v | _]), do: first_header_value(v)
  defp first_header_value([]), do: nil
  defp first_header_value(v) when is_binary(v), do: v
  defp first_header_value(nil), do: nil
  defp first_header_value(v), do: to_string(v)

  defp get_location_header(headers), do: header_value(headers, "location")

  defp extract_content_type(headers) do
    header_value(headers, "content-type") || "text/plain"
  end

  defp format_body(body, content_type, max_length) when is_binary(body) do
    cond do
      String.contains?(content_type, "text/html") ->
        body |> strip_html_tags() |> truncate(max_length)

      String.contains?(content_type, "application/json") or
          String.contains?(content_type, "text/json") ->
        case Jason.decode(body) do
          {:ok, decoded} ->
            decoded |> Jason.encode!(pretty: true) |> truncate(max_length)

          _ ->
            truncate(body, max_length)
        end

      true ->
        truncate(body, max_length)
    end
  end

  defp format_body(body, content_type, max_length) do
    # Body may have been decoded to a map/list by Req for JSON responses
    cond do
      String.contains?(content_type, "application/json") ->
        body |> Jason.encode!(pretty: true) |> truncate(max_length)

      is_map(body) or is_list(body) ->
        body |> inspect(pretty: true, limit: max_length) |> truncate(max_length)

      true ->
        body |> to_string() |> truncate(max_length)
    end
  end

  # Strip HTML tags and decode common HTML entities, collapsing whitespace.
  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_html_entities()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "\n[truncated at #{max_length} characters]"
    else
      text
    end
  end
end
