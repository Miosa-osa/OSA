defmodule OptimalSystemAgent.Utils.WireEncoding do
  @moduledoc """
  The last line of defence between OSA's message history and a JSON encoder.

  ## Why this exists

  Elixir binaries are byte strings. Nothing in the agent loop requires them to
  be valid UTF-8, so a tool that reads bytes off a disk — a latin-1 encoded
  source file, a compiled artifact, a `git` blob, a command's stdout — can put
  arbitrary bytes into a `tool` message and every layer in between will carry
  them without complaint.

  The complaint arrives at the wire. Every provider request body is handed to
  `Jason.encode_to_iodata!/1` (via `Req`'s `:json` option), and Jason RAISES on
  a binary it cannot decode:

      ** (Jason.EncodeError) invalid byte 0xDA in <<...>>

  `Providers.Registry.do_apply_provider/3` rescues that raise into
  `{:error, "Provider error: invalid byte 0xDA in <<…>>"}`, which the react
  loop reports as a failed LLM call. The turn ENDS. Measured end to end: a
  single `file_grep` hit on a latin-1 line killed the turn and the session
  produced a 0-byte patch, and because the failure surfaced as a provider error
  it was scored against the MODEL rather than against OSA.

  Sanitizing at the tool boundary is necessary but not sufficient — there are
  dozens of tools, plus MCP servers and plugins OSA does not own, and every one
  of them is one `File.read/1` away from re-introducing this. So the guarantee
  lives here, at the single point every provider dispatch passes through, and
  the tool-level behaviour (a readable "this file is not UTF-8" note instead of
  mojibake) is a quality improvement layered on top rather than the safety net.

  ## What it does

  `scrub_messages/1` walks the outbound message list and replaces every
  undecodable byte in every binary with U+FFFD (`Utils.Text.scrub_utf8/1`).
  Replacement rather than truncation: dropping the tail after the first bad
  byte would silently delete most of a grep result over a non-UTF-8 file.

  ## Cost

  A retry or a fallback hop re-enters here on every attempt, so the common case
  must be free. It is: `valid?/1` short-circuits on the first invalid binary it
  finds and returns the list UNCHANGED (same term, no rebuild) when everything
  is already valid. `String.valid?/1` is a BIF over the raw bytes, so the scan
  is a linear pass with no allocation, against an HTTP round trip.

  Idempotent — scrubbing an already-scrubbed list is a no-op.
  """

  alias OptimalSystemAgent.Utils.Text

  @doc """
  Coerce every binary reachable from `messages` to valid UTF-8.

  Returns the list unchanged (the identical term) when it is already clean.
  """
  @spec scrub_messages(term()) :: term()
  def scrub_messages(messages) when is_list(messages) do
    if valid?(messages), do: messages, else: scrub_term(messages)
  end

  def scrub_messages(other), do: other

  @doc """
  True when nothing reachable from `term` is an invalid-UTF-8 binary.

  Public because it is the cheap guard callers want before deciding to rebuild,
  and because the tests assert on it directly.
  """
  @spec valid?(term()) :: boolean()
  def valid?(bin) when is_binary(bin), do: String.valid?(bin)
  def valid?(list) when is_list(list), do: Enum.all?(list, &valid?/1)

  def valid?(%_struct{} = struct) do
    struct |> Map.from_struct() |> valid?()
  end

  def valid?(map) when is_map(map) do
    Enum.all?(map, fn {k, v} -> valid?(k) and valid?(v) end)
  end

  def valid?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> valid?()
  def valid?(_other), do: true

  # A whole-term walk rather than a hand-listed set of fields. The shapes that
  # can carry file bytes are not stable: `content` can be a string OR a list of
  # typed blocks (`%{"type" => "text", "text" => …}`, image parts), a tool
  # result can hang off `:content`, `"content"`, `:tool_calls[].arguments` (a
  # nested map whose leaves the model chose), or a provider-specific key an MCP
  # tool invented. Enumerating them is how a fix ends up covering `file_grep`
  # and missing `shell_execute`; walking the term cannot miss one.
  #
  # Structs are rebuilt in place so a `%Message{}`-style wrapper keeps its type.
  defp scrub_term(bin) when is_binary(bin), do: Text.scrub_utf8(bin)
  defp scrub_term(list) when is_list(list), do: Enum.map(list, &scrub_term/1)

  defp scrub_term(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> scrub_term()
    |> then(&struct(module, &1))
  end

  defp scrub_term(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {scrub_term(k), scrub_term(v)} end)
  end

  defp scrub_term(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> scrub_term() |> List.to_tuple()
  end

  defp scrub_term(other), do: other
end
