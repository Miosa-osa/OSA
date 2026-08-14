defmodule OptimalSystemAgent.Tools.Builtins.Download.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `download`.

    * `validate/2`          — type checks url and path fields
    * `check_permissions/2` — URL scheme, SSRF guard, write-path allowlist
    * `execute/2`           — stream download via Req
  """

  alias OptimalSystemAgent.Tools.Builtins.Download.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"url" => url, "path" => path} = input, _ctx)
      when is_binary(url) and is_binary(path),
      do: {:ok, input}

  def validate(%{"url" => _, "path" => _}, _ctx),
    do: {:error, "url and path must be strings", -32_602}

  def validate(%{"url" => _}, _ctx),
    do: {:error, "Missing required parameter: path", -32_602}

  def validate(%{"path" => _}, _ctx),
    do: {:error, "Missing required parameter: url", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: url, path", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"url" => url, "path" => path} = input, _ctx) do
    with :ok <- validate_url_scheme(url),
         {:ok, expanded} <- resolve_path(path),
         :ok <- write_allowed?(expanded) do
      {:allow, Map.put(input, "_expanded_path", expanded)}
    else
      {:error, reason} -> {:deny, "Access denied: #{reason}"}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"url" => url} = input, _ctx) do
    expanded = input["_expanded_path"] || elem(resolve_path(input["path"]), 1)

    case File.mkdir_p(Path.dirname(expanded)) do
      :ok ->
        stream_download(url, expanded, Constants.max_redirects())

      {:error, reason} ->
        {:error, "Cannot create directory: #{:file.format_error(reason)}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp validate_url_scheme(url) do
    uri = URI.parse(url)

    case uri.scheme do
      "https" ->
        check_host_not_private(uri.host || "")

      "http" ->
        host = uri.host || ""

        if host == "localhost" or String.starts_with?(host, "127.") or host == "::1" do
          :ok
        else
          {:error, "Only HTTPS URLs are allowed for download (got http://#{host})"}
        end

      other ->
        {:error, "Unsupported URL scheme: #{other}. Only https:// is allowed."}
    end
  end

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

  # IPv4 private ranges
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  # IPv6 loopback ::1
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv6 link-local fe80::/10
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  defp private_ip?(_), do: false

  defp resolve_path(path) do
    normalized =
      if relative_path?(path) do
        Path.join("~/.osa/workspace", path)
      else
        path
      end

    {:ok, Path.expand(normalized)}
  end

  defp relative_path?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end

  defp write_allowed?(expanded_path) do
    if dotfile_outside_osa?(expanded_path) do
      {:error, "writing to dotfiles outside ~/.osa/ is not allowed"}
    else
      blocked =
        Enum.any?(Constants.blocked_write_paths(), fn pattern ->
          String.contains?(expanded_path, pattern)
        end)

      if blocked do
        {:error, "#{expanded_path} targets a protected system location"}
      else
        check_path =
          if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

        allowed =
          Enum.any?(allowed_write_paths(), fn allowed ->
            String.starts_with?(check_path, allowed)
          end)

        if allowed, do: :ok, else: {:error, "#{expanded_path} is outside allowed write paths"}
      end
    end
  end

  # Shared write allowlist — configured roots PLUS the session workspace. A
  # private copy here was blind to the session's `working_dir`, so a download
  # into the workspace was refused in any container whose workspace is not
  # under `$HOME`.
  defp allowed_write_paths, do: OptimalSystemAgent.Agent.Safety.PathPolicy.write_roots()

  defp osa_path, do: Path.expand("~/.osa") <> "/"

  defp dotfile_outside_osa?(expanded_path) do
    home = Path.expand("~")

    relative =
      case String.split_at(expanded_path, byte_size(home)) do
        {^home, rest} -> rest
        _ -> nil
      end

    case relative do
      "/" <> rest ->
        first_component = rest |> String.split("/") |> List.first()
        starts_with_dot = String.starts_with?(first_component, ".")
        under_osa = String.starts_with?(expanded_path, osa_path())
        starts_with_dot and not under_osa

      _ ->
        false
    end
  end

  defp stream_download(_url, path, remaining) when remaining < 0 do
    File.rm(path)
    {:error, "Too many redirects"}
  end

  defp stream_download(url, path, remaining) do
    response =
      Req.get(url,
        receive_timeout: 120_000,
        redirect: false,
        decode_body: false
      )

    case response do
      {:ok, %Req.Response{status: status, headers: headers}}
      when status in [301, 302, 307, 308] ->
        location = get_location_header(headers)

        case location do
          nil ->
            File.rm(path)
            {:error, "Redirect response (HTTP #{status}) missing Location header"}

          redirect_url ->
            case validate_url_scheme(redirect_url) do
              {:error, reason} ->
                File.rm(path)
                {:error, "Blocked redirect to #{redirect_url}: #{reason}"}

              :ok ->
                stream_download(redirect_url, path, remaining - 1)
            end
        end

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case File.write(path, body) do
          :ok ->
            size = byte_size(body)
            {:ok, "Downloaded #{url} to #{path} (#{size} bytes)"}

          {:error, reason} ->
            {:error, "Download succeeded but write failed: #{reason}"}
        end

      {:ok, %Req.Response{status: status}} ->
        File.rm(path)
        {:error, "HTTP #{status} downloading #{url}"}

      {:error, %Req.TransportError{reason: :body_too_large}} ->
        File.rm(path)
        max_mb = div(Constants.max_download_bytes(), 1024 * 1024)
        {:error, "Download aborted: file exceeds maximum size of #{max_mb}MB"}

      {:error, reason} ->
        File.rm(path)
        {:error, "Download failed: #{inspect(reason)}"}
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
end
