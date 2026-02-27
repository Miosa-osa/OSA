defmodule OptimalSystemAgent.Tools.Builtins.WebFetch do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @max_body_bytes 15_000
  @timeout_ms 15_000

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description, do: "Fetch URL content and extract text. Use for reading web pages, docs, APIs."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "The URL to fetch"},
        "prompt" => %{"type" => "string", "description" => "What to extract from the page (used as context label)"}
      },
      "required" => ["url"]
    }
  end

  @impl true
  def execute(%{"url" => url} = params) do
    prompt = params["prompt"] || "Content"

    if not valid_url?(url) do
      {:error, "Invalid URL: #{url}"}
    else
      ensure_started()

      url_charlist = String.to_charlist(url)
      headers = [{~c"User-Agent", ~c"OSA/1.0"}]
      http_opts = [timeout: @timeout_ms, connect_timeout: 5_000, ssl: ssl_opts()]
      opts = [body_format: :binary]

      case :httpc.request(:get, {url_charlist, headers}, http_opts, opts) do
        {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
          text = body |> strip_html() |> String.slice(0, @max_body_bytes)
          {:ok, "#{prompt} from #{url}:\n\n#{text}"}
        {:ok, {{_, status, _}, _headers, _body}} ->
          {:error, "HTTP #{status} from #{url}"}
        {:error, reason} ->
          {:error, "Fetch failed: #{inspect(reason)}"}
      end
    end
  end
  def execute(_), do: {:error, "Missing required parameter: url"}

  defp valid_url?(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp ensure_started do
    :inets.start()
    :ssl.start()
  rescue
    _ -> :ok
  end

  defp ssl_opts do
    [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]
  rescue
    _ -> [verify: :verify_none]
  end

  defp strip_html(body) when is_binary(body) do
    body
    |> String.replace(~r/<script[^>]*>[\s\S]*?<\/script>/i, "")
    |> String.replace(~r/<style[^>]*>[\s\S]*?<\/style>/i, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
  defp strip_html(_), do: ""
end
