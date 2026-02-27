defmodule OptimalSystemAgent.NIF do
  @moduledoc """
  Rust NIF bindings for hot-path operations.

  Every NIF has a safe Elixir fallback — the system works identically
  without Rust compiled. Set OSA_SKIP_NIF=true to bypass compilation.
  """

  use Rustler,
    otp_app: :optimal_system_agent,
    crate: :osa_nif,
    skip_compilation?: System.get_env("OSA_SKIP_NIF", "false") == "true"

  # NIF stubs — replaced by Rust at load time
  def count_tokens(_text), do: :erlang.nif_error(:nif_not_loaded)
  def calculate_weight(_text), do: :erlang.nif_error(:nif_not_loaded)
  def word_count(_text), do: :erlang.nif_error(:nif_not_loaded)

  # Safe wrappers — ALWAYS use these in business logic

  @doc "Count BPE tokens. Falls back to heuristic if NIF unavailable."
  def safe_count_tokens(text) when is_binary(text) do
    count_tokens(text)
  rescue
    _ -> heuristic_count(text)
  end

  @doc "Calculate signal weight. Falls back to Elixir implementation."
  def safe_calculate_weight(text) when is_binary(text) do
    calculate_weight(text)
  rescue
    _ -> OptimalSystemAgent.Signal.Classifier.calculate_weight(text)
  end

  @doc "Count words. Falls back to Elixir implementation."
  def safe_word_count(text) when is_binary(text) do
    word_count(text)
  rescue
    _ -> text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp heuristic_count(text) do
    words = text |> String.split(~r/\s+/, trim: true) |> length()
    punctuation = Regex.scan(~r/[^\w\s]/, text) |> length()
    round(words * 1.3 + punctuation * 0.5)
  end
end
