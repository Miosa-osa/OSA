defmodule OptimalSystemAgent.Utils do
  @moduledoc """
  Shared utility functions used across the OptimalSystemAgent codebase.

  Sub-modules:
  - `OptimalSystemAgent.Utils.Tokens` — heuristic token estimation
  - `OptimalSystemAgent.Utils.Text`   — string manipulation helpers
  - `OptimalSystemAgent.Utils.ID`     — unique ID generation
  """
end

defmodule OptimalSystemAgent.Utils.Tokens do
  @moduledoc """
  Token estimation utilities.

  The heuristic formula (words * 1.3 + punctuation * 0.5) is an empirically
  derived approximation of BPE token counts for English text. It is used as
  a fallback when the Go tokenizer or Rust NIF is unavailable.
  """

  @doc """
  Heuristic token count: words * 1.3 + punctuation * 0.5.

  Returns 0 for non-binary inputs.
  """
  @spec estimate(String.t() | any()) :: non_neg_integer()
  def estimate(text) when is_binary(text) do
    words = text |> String.split(~r/\s+/, trim: true) |> length()
    punctuation = Regex.scan(~r/[^\w\s]/, text) |> length()
    round(words * 1.3 + punctuation * 0.5)
  end

  def estimate(_), do: 0
end

defmodule OptimalSystemAgent.Utils.Text do
  @moduledoc """
  String manipulation helpers used across the codebase.
  """

  @doc """
  Truncates `str` to at most `max_len` characters (Unicode-aware).

  If the string exceeds `max_len`, it is sliced to `max_len - 1` characters
  and an ellipsis character is appended. Returns `""` for non-binary inputs.
  """
  @spec truncate(String.t() | any(), non_neg_integer()) :: String.t()
  def truncate(str, max_len) when is_binary(str) do
    if String.length(str) <= max_len do
      str
    else
      String.slice(str, 0, max_len - 1) <> "…"
    end
  end

  def truncate(_, _), do: ""

  @doc """
  Strips leading and trailing Markdown code fences from `content`.

  Handles optional language tags (e.g. ` ```json `).
  """
  @spec strip_markdown_fences(String.t() | any()) :: String.t()
  def strip_markdown_fences(content) when is_binary(content) do
    content
    |> String.replace(~r/^```(?:json)?\s*\n?/, "")
    |> String.replace(~r/\n?\s*```\s*$/, "")
  end

  def strip_markdown_fences(content), do: content

  @doc """
  Converts any value to a string safely.

  - `nil`     → `""`
  - binary    → as-is
  - atom      → `Atom.to_string/1`
  - map/list  → `Jason.encode!/1`
  - other     → `inspect/1`
  """
  @spec safe_to_string(any()) :: String.t()
  def safe_to_string(nil), do: ""
  def safe_to_string(val) when is_binary(val), do: val
  def safe_to_string(val) when is_atom(val), do: Atom.to_string(val)
  def safe_to_string(val) when is_map(val), do: Jason.encode!(val)
  def safe_to_string(val) when is_list(val), do: Jason.encode!(val)
  def safe_to_string(val), do: inspect(val)

  @doc """
  Returns the current UTC time as an ISO 8601 string.
  """
  @spec now_iso() :: String.t()
  def now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

defmodule OptimalSystemAgent.Utils.ID do
  @moduledoc """
  Unique ID generation using cryptographically strong random bytes.
  """

  @doc """
  Generates a random 16-character hex ID, optionally prefixed.

      iex> OptimalSystemAgent.Utils.ID.generate()
      "a3f2c1d4e5b6a7c8"

      iex> OptimalSystemAgent.Utils.ID.generate("task")
      "task_a3f2c1d4e5b6a7c8"
  """
  @spec generate(String.t() | nil) :: String.t()
  def generate(prefix \\ nil) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    if prefix, do: "#{prefix}_#{id}", else: id
  end
end
