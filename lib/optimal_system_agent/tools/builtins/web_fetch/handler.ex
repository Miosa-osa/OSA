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
      case :inet.getaddrs(charlist, :inet) do
        {:ok, v4} -> v4
        _ -> []
      end ++
        case :inet.getaddrs(charlist, :inet6) do
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
        redirect: false
      )

    case response do
      {:ok, %Req.Response{status: status, headers: headers}}
      when status in [301, 302, 307, 308] ->
        location = get_location_header(headers)

        case location do
          nil ->
            {:error, "Redirect response (HTTP #{status}) missing Location header"}

          redirect_url ->
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
        {:ok, "#{url}\n#{content_type}\n---\n#{formatted}"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status} fetching #{url}"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Network error fetching #{url}: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Error fetching #{url}: #{inspect(reason)}"}
    end
  end

  defp get_location_header(headers) when is_list(headers) do
    case List.keyfind(headers, "location", 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp get_location_header(headers) when is_map(headers) do
    Map.get(headers, "location")
  end

  defp get_location_header(_), do: nil

  defp extract_content_type(headers) when is_list(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, value} -> value
      nil -> "text/plain"
    end
  end

  defp extract_content_type(headers) when is_map(headers) do
    Map.get(headers, "content-type", "text/plain")
  end

  defp extract_content_type(_), do: "text/plain"

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
