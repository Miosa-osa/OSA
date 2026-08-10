defmodule OptimalSystemAgent.Auth.AwsSigV4 do
  @moduledoc """
  AWS Signature Version 4 request signing, hand-rolled on `:crypto`.

  ## Why this exists rather than a dependency

  Every Elixir AWS client pulls in a large surface — a whole SDK, an HTTP
  client of its own choosing, or a code-generated API layer — to solve a
  problem that is eighty lines of HMAC. Bedrock needs exactly one thing from
  AWS: a correctly signed HTTPS request. Adding a dependency for that would
  also add its transitive supply chain, its release cadence and its opinion
  about which HTTP client OSA uses, all of which OSA already decided.

  ## What is signed, and the two encodings that trip people up

  There are two separate encodings in play and mixing them up produces a
  `SignatureDoesNotMatch` that looks like a credential problem:

    * **The path actually sent on the wire** keeps characters that RFC 3986
      permits in a path segment. A Bedrock model id contains a colon
      (`anthropic.claude-…-v1:0`) and a colon is a legal `pchar`, so the
      request line carries it literally.
    * **The path in the canonical request** percent-encodes everything outside
      the unreserved set, so that same colon becomes `%3A` — *only* in the
      string that is hashed, never in the request.

  This module therefore takes the literal path and does the canonical-form
  encoding itself. Callers must not pre-encode.

  ## Scope

  Signs a single request with a static credential (access key + secret, plus
  an optional session token). It does not fetch, cache or refresh
  credentials — `Auth.AwsCredentials` owns that, and keeping the two apart is
  what makes this module a pure function that can be tested against AWS's own
  published test vectors.

  ## Secrets

  Nothing here logs. The secret access key is used only as HMAC key material
  and never appears in the returned headers; the returned `authorization`
  header contains the access key **id** (not secret) and a signature, which is
  the same information AWS itself puts on the wire.
  """

  @algorithm "AWS4-HMAC-SHA256"

  @typedoc """
  A resolved AWS credential. `session_token` is present for temporary
  credentials (STS, SSO, IMDS, `AWS_SESSION_TOKEN`) and `nil` for long-lived
  IAM user keys.
  """
  @type credentials :: %{
          required(:access_key_id) => String.t(),
          required(:secret_access_key) => String.t(),
          optional(:session_token) => String.t() | nil
        }

  @doc """
  Sign a request and return the complete header list to send.

  `headers` are the caller's own headers (e.g. `content-type`). `host`,
  `x-amz-date`, `x-amz-security-token` and `authorization` are added here;
  supplying them yourself is not an error but they will be overwritten,
  because a header that is signed and a header that is sent must be the same
  string or the signature is meaningless.

  Options:

    * `:region`  — required, e.g. `"us-east-1"`
    * `:service` — required, e.g. `"bedrock"`
    * `:now`     — a `DateTime` in UTC, for deterministic tests
  """
  @spec sign(String.t(), String.t(), [{String.t(), String.t()}], binary(), credentials(), keyword()) ::
          [{String.t(), String.t()}]
  def sign(method, url, headers, body, creds, opts) do
    region = Keyword.fetch!(opts, :region)
    service = Keyword.fetch!(opts, :service)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    uri = URI.parse(url)
    amz_date = amz_datetime(now)
    date_stamp = String.slice(amz_date, 0, 8)

    base_headers =
      headers
      |> Enum.reject(fn {k, _} ->
        String.downcase(k) in ["host", "x-amz-date", "x-amz-security-token", "authorization"]
      end)
      |> Kernel.++([{"host", host_header(uri)}, {"x-amz-date", amz_date}])
      |> maybe_session_token(creds)

    canonical_headers = canonical_headers(base_headers)
    signed_headers = signed_headers(base_headers)

    canonical_request =
      Enum.join(
        [
          String.upcase(method),
          canonical_path(uri.path),
          canonical_query(uri.query),
          canonical_headers,
          signed_headers,
          hex(sha256(body))
        ],
        "\n"
      )

    scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

    string_to_sign =
      Enum.join([@algorithm, amz_date, scope, hex(sha256(canonical_request))], "\n")

    signature =
      creds
      |> signing_key(date_stamp, region, service)
      |> hmac(string_to_sign)
      |> hex()

    authorization =
      "#{@algorithm} Credential=#{creds.access_key_id}/#{scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    base_headers ++ [{"authorization", authorization}]
  end

  @doc """
  The canonical request string for a signature, exposed for tests.

  AWS publishes canonical-request test vectors, and being able to diff against
  them directly is the difference between "the signature is wrong" and knowing
  *which* of the six canonical lines is wrong.
  """
  @spec canonical_path(String.t() | nil) :: String.t()
  def canonical_path(nil), do: "/"
  def canonical_path(""), do: "/"

  def canonical_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &uri_encode/1)
  end

  @doc false
  @spec canonical_query(String.t() | nil) :: String.t()
  def canonical_query(nil), do: ""
  def canonical_query(""), do: ""

  def canonical_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {uri_encode(URI.decode(k)), uri_encode(URI.decode(v))}
        [k] -> {uri_encode(URI.decode(k)), ""}
      end
    end)
    # Sorted by encoded name, then encoded value — AWS compares byte-wise on
    # the ENCODED forms, so sorting the decoded ones would order `%20` and `+`
    # differently from the server.
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  # AWS's UriEncode: everything outside the RFC 3986 unreserved set is
  # percent-encoded with UPPERCASE hex. `/` is NOT exempt here because this is
  # applied per path segment (the caller splits on `/`) and to query
  # names/values, where a literal slash must encode.
  @doc false
  @spec uri_encode(String.t()) :: String.t()
  def uri_encode(segment) do
    segment
    |> :binary.bin_to_list()
    |> Enum.map_join(fn c ->
      cond do
        c in ?A..?Z or c in ?a..?z or c in ?0..?9 -> <<c>>
        c in [?-, ?_, ?., ?~] -> <<c>>
        true -> "%" <> (<<c>> |> Base.encode16(case: :upper))
      end
    end)
  end

  # ── canonical pieces ──────────────────────────────────────────────────────

  defp canonical_headers(headers) do
    headers
    |> Enum.map(fn {k, v} -> {String.downcase(k), collapse_ws(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(fn {k, v} -> "#{k}:#{v}\n" end)
  end

  defp signed_headers(headers) do
    headers
    |> Enum.map(fn {k, _} -> String.downcase(k) end)
    |> Enum.sort()
    |> Enum.join(";")
  end

  # Sequential whitespace inside a header value collapses to one space, and the
  # value is trimmed. Skipping this is invisible until a caller passes a header
  # with a double space in it.
  defp collapse_ws(value) do
    value |> to_string() |> String.trim() |> String.replace(~r/\s+/, " ")
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    default = if scheme == "https", do: 443, else: 80
    if is_nil(port) or port == default, do: host, else: "#{host}:#{port}"
  end

  defp maybe_session_token(headers, %{session_token: t}) when is_binary(t) and t != "",
    do: headers ++ [{"x-amz-security-token", t}]

  defp maybe_session_token(headers, _), do: headers

  # ── crypto ────────────────────────────────────────────────────────────────

  defp signing_key(creds, date_stamp, region, service) do
    ("AWS4" <> creds.secret_access_key)
    |> hmac(date_stamp)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha256(data), do: :crypto.hash(:sha256, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  @doc false
  @spec amz_datetime(DateTime.t()) :: String.t()
  def amz_datetime(dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase)

    :io_lib.format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ", [
      dt.year,
      dt.month,
      dt.day,
      dt.hour,
      dt.minute,
      dt.second
    ])
    |> IO.iodata_to_binary()
  end
end
