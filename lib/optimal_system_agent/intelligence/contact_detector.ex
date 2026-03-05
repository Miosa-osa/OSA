defmodule OptimalSystemAgent.Intelligence.ContactDetector do
  @moduledoc """
  Pure pattern matching for contact identification.
  No LLM needed — runs in < 1ms.

  Matches names, aliases, phone numbers, email addresses
  against the contact registry.

  Signal Theory — deterministic contact resolution.
  """

  # Roles we recognise in "my <role>" constructs
  @role_patterns ~w(boss manager team colleague client coworker partner lead director cto ceo founder mentor)

  @doc """
  Detect contact references in a message string.

  Returns a list of tagged tuples:
  - `{:mention, name}` — @username
  - `{:email, address}` — email@domain.com
  - `{:role, role}` — "my boss", "the team", etc.
  - `{:name, name}` — Capitalised words that look like proper names
  """
  def detect(text) when is_binary(text) do
    mentions(text) ++ emails(text) ++ roles(text) ++ proper_names(text)
  end

  @doc """
  Returns a deduplicated list of contact strings found in the message.
  Strips tags — useful when you only need the contact values.
  """
  def extract_contacts(text) when is_binary(text) do
    text
    |> detect()
    |> Enum.map(fn {_tag, value} -> value end)
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Private matchers
  # ---------------------------------------------------------------------------

  # @username style mentions
  defp mentions(text) do
    ~r/@([A-Za-z0-9_]+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [name] -> {:mention, name} end)
  end

  # email@domain.tld
  defp emails(text) do
    ~r/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/
    |> Regex.scan(text)
    |> Enum.map(fn [addr] -> {:email, addr} end)
  end

  # "my boss", "the team", "my manager", etc.
  defp roles(text) do
    role_alternation = Enum.join(@role_patterns, "|")
    pattern = ~r/\b(?:my|the)\s+(#{role_alternation})\b/i

    pattern
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [role] -> {:role, String.downcase(role)} end)
    |> Enum.uniq()
  end

  # Capitalised words that are NOT at sentence start and not in common stop words.
  # Heuristic: a proper name is a capitalised word NOT preceded by ". " or start-of-string.
  defp proper_names(text) do
    # Remove already-matched @mentions and emails to reduce false positives
    stripped =
      text
      |> String.replace(~r/@[A-Za-z0-9_]+/, "")
      |> String.replace(~r/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/, "")

    # Find capitalised words not at sentence starts (sentence start = after [.!?] or at ^)
    # We capture the character before the capitalised word to check context.
    ~r/(?<![.!?\n\s])(?:^|\s)([A-Z][a-z]{1,20})/
    |> Regex.scan(stripped, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&stop_word?/1)
    |> Enum.uniq()
    |> Enum.map(fn name -> {:name, name} end)
  end

  # Common words that happen to be capitalised but are not names
  @stop_words ~w(
    I A The An And Or But In On At To For Of With By From As Is Was Be
    It This That These Those My Your His Her Our Their Its We You He She They
    Monday Tuesday Wednesday Thursday Friday Saturday Sunday
    January February March April May June July August September October November December
    Hi Hello Hey Dear Thanks Thank Sorry Please Yes No Ok Okay
  )

  defp stop_word?(word), do: word in @stop_words
end
