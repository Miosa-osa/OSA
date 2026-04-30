defmodule OptimalSystemAgent.ContextRefs.Resolvers.Url do
  @moduledoc "Resolves @url:https://... by fetching the URL body."

  @spec resolve(String.t(), pos_integer()) :: {:ok, map()} | {:error, map()}
  def resolve(url, budget) do
    case fetch_url(url) do
      {:ok, body} ->
        truncated = String.slice(body, 0, budget)
        {:ok, %{type: :url, source: "@url:#{url}", content: truncated}}

      {:error, reason} ->
        {:error,
         %{
           type: :error,
           source: "@url:#{url}",
           content: "[Failed to fetch #{url}: #{reason}]"
         }}
    end
  end

  defp fetch_url(url) do
    # Req is available in this project (see mix.exs {:req, "~> 0.5"})
    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, to_string(body)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, err} ->
        {:error, inspect(err)}
    end
  end
end
