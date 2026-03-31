defmodule OptimalSystemAgent.Tools.Builtins.Download do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @max_download_bytes 50 * 1024 * 1024
  @max_redirects 3

  @blocked_write_paths [
    ".ssh/",
    ".gnupg/",
    "/etc/",
    "/boot/",
    "/usr/",
    "/bin/",
    "/sbin/",
    "/var/",
    ".aws/",
    ".env"
  ]

  @default_allowed_write_paths ["~", "/tmp"]

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "download"

  @impl true
  def description, do: "Download a file from a URL to a local path."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" => "URL to download from (must be https://)"
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Local path to save the file to. Relative paths are rooted at ~/.osa/workspace/"
        }
      },
      "required" => ["url", "path"]
    }
  end

  @impl true
  def execute(%{"url" => url, "path" => path}) when is_binary(url) and is_binary(path) do
    with :ok <- validate_url(url),
         {:ok, expanded} <- resolve_path(path),
         :ok <- write_allowed?(expanded) do
      do_download(url, expanded)
    end
  end

  def execute(%{"url" => _, "path" => _}), do: {:error, "url and path must be strings"}
  def execute(%{"url" => _}), do: {:error, "Missing required parameter: path"}
  def execute(%{"path" => _}), do: {:error, "Missing required parameter: url"}
  def execute(_), do: {:error, "Missing required parameters: url, path"}

  # --- Private ---

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
          {:error, "Only HTTPS URLs are allowed for download (got http://#{host})"}
        end

      other ->
        {:error, "Unsupported URL scheme: #{other}. Only https:// is allowed."}
    end
  end

  # Resolve the hostname and reject if any returned address is private/loopback/link-local.
  # This guards against DNS rebinding as well as direct private-IP URLs.
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

  # Returns true if the IP tuple represents a private, loopback, or link-local address.
  #
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

  # IPv6 loopback ::1 — all zeros except last
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv6 link-local fe80::/10 — first 16-bit word spans 0xFE80–0xFEBF
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
      {:error, "Access denied: writing to dotfiles outside ~/.osa/ is not allowed"}
    else
      blocked =
        Enum.any?(@blocked_write_paths, fn pattern ->
          String.contains?(expanded_path, pattern)
        end)

      if blocked do
        {:error, "Access denied: #{expanded_path} targets a protected system location"}
      else
        check_path =
          if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

        allowed =
          Enum.any?(allowed_write_paths(), fn allowed ->
            String.starts_with?(check_path, allowed)
          end)

        if allowed do
          :ok
        else
          {:error, "Access denied: #{expanded_path} is outside allowed write paths"}
        end
      end
    end
  end

  defp allowed_write_paths do
    configured =
      Application.get_env(
        :optimal_system_agent,
        :allowed_write_paths,
        @default_allowed_write_paths
      )

    Enum.map(configured, fn p ->
      expanded = Path.expand(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end

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

  defp do_download(url, expanded_path) do
    case File.mkdir_p(Path.dirname(expanded_path)) do
      :ok ->
        stream_download(url, expanded_path, @max_redirects)

      {:error, reason} ->
        {:error, "Cannot create directory: #{:file.format_error(reason)}"}
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
            case validate_url(redirect_url) do
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
        # Clean up partial file on failure
        File.rm(path)
        {:error, "HTTP #{status} downloading #{url}"}

      {:error, %Req.TransportError{reason: :body_too_large}} ->
        File.rm(path)
        max_mb = div(@max_download_bytes, 1024 * 1024)
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
