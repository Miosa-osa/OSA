defmodule OptimalSystemAgent.Memory.VIGIL do
  @moduledoc """
  VIGIL — Vigilant Introspection for Guided Iterative Learning.

  VIGIL is the SICA Phase 2 (INTROSPECT) component. It classifies error
  messages into structured `{category, subcategory, suggestion}` triples that
  the learning engine uses to build actionable patterns.

  ## Classification output

      {category, subcategory, suggestion}

  Where:
  * `category`    — atom top-level error class (e.g. `:io_error`, `:network_error`)
  * `subcategory` — string refinement (e.g. `"file_not_found"`, `"timeout"`)
  * `suggestion`  — human-readable corrective hint

  ## Deterministic — no LLM required

  VIGIL uses regex pattern matching. Classification is synchronous, < 1 ms,
  and never fails (falls back to `{:unknown_error, "unclassified", hint}`).
  """

  @type category :: atom()
  @type subcategory :: String.t()
  @type suggestion :: String.t()
  @type classification :: {category(), subcategory(), suggestion()}

  # ---------------------------------------------------------------------------
  # Rule table: {regex, category, subcategory, suggestion}
  # ---------------------------------------------------------------------------

  @rules [
    # File-system errors
    {~r/\benoent\b|\bno such file\b|\bnot found\b/i, :io_error, "file_not_found",
     "Verify the file path exists before reading or writing."},
    {~r/\beacces\b|\bpermission denied\b/i, :io_error, "permission_denied",
     "Check file permissions or run with appropriate privileges."},
    {~r/\beexist\b|\balready exists\b/i, :io_error, "file_exists",
     "Use File.rm/1 or an overwrite flag before writing."},
    {~r/\beis_dir\b|\bis a directory\b/i, :io_error, "is_a_directory",
     "Target path is a directory; use a file path instead."},
    {~r/\benospc\b|\bno space left\b/i, :io_error, "disk_full",
     "Free disk space or write to a different volume."},

    # Network / HTTP errors
    {~r/\btimeout\b|\bconnection timed out\b/i, :network_error, "timeout",
     "Increase timeout or retry with exponential back-off."},
    {~r/\bconnection refused\b|\beconnrefused\b/i, :network_error, "connection_refused",
     "Confirm the remote service is running and the port is correct."},
    {~r/\bdns\b|\bnxdomain\b|\bname or service not known\b/i, :network_error, "dns_failure",
     "Check the hostname spelling and DNS configuration."},
    {~r/\bssl\b|\btls\b|\bcertificate\b/i, :network_error, "ssl_error",
     "Verify the TLS certificate and ensure the CA chain is trusted."},
    {~r/\b4[0-9]{2}\b|\bbad request\b|\bunauthorized\b|\bforbidden\b|\bnot found\b/i, :http_error,
     "client_error", "Check the request parameters, authentication, and endpoint URL."},
    {~r/\b5[0-9]{2}\b|\binternal server error\b|\bbad gateway\b|\bservice unavailable\b/i,
     :http_error, "server_error",
     "The remote server returned an error; retry or contact the API provider."},

    # Argument / type errors
    {~r/\bbad argument\b|\bargumenterror\b|\binvalid argument\b/i, :argument_error,
     "bad_argument", "Validate argument types and values before calling the function."},
    {~r/\bfunctionclauseerror\b|\bfunction clause\b|\bno function clause\b/i, :argument_error,
     "no_matching_clause", "Ensure the argument matches an expected pattern for the function."},
    {~r/\bmatcherror\b|\bmatch error\b|\bno match\b/i, :argument_error, "match_error",
     "Check the pattern match; add a catch-all clause or validate input."},

    # Memory / resource errors
    {~r/\bout of memory\b|\benomem\b/i, :resource_error, "out_of_memory",
     "Reduce memory usage, increase heap, or process data in smaller chunks."},
    {~r/\bmax_heap_size\b|\bprocess killed\b/i, :resource_error, "heap_limit",
     "Increase :max_heap_size or stream large data instead of loading it all."},

    # Process / concurrency errors
    {~r/\bnoproc\b|\bno process\b|\bprocess not alive\b/i, :process_error, "no_process",
     "The target process has exited; check the supervision tree."},
    {~r/\bcall_timeout\b|\bgenserver.*timeout\b/i, :process_error, "genserver_timeout",
     "Increase the GenServer timeout or investigate slow handle_call."},

    # Encoding / parsing errors
    {~r/\bjason\b|\bjson\b|\binvalid json\b|\bunexpected byte\b/i, :parse_error, "json_parse",
     "Validate the JSON structure and ensure the content type is correct."},
    {~r/\byaml\b|\binvalid yaml\b/i, :parse_error, "yaml_parse",
     "Validate the YAML syntax; watch for indentation and special characters."},

    # Tool-specific
    {~r/\bblocked:\b|\bblocked pattern\b/i, :security_error, "blocked_command",
     "The command was blocked by the shell security policy; use a safer alternative."},
    {~r/\bunknown tool\b|\btool not found\b/i, :tool_error, "unknown_tool",
     "Check the tool name spelling; use list_tools to see available tools."},
    {~r/\bmissing required param\b|\bmissing param\b/i, :tool_error, "missing_params",
     "Supply all required parameters for this tool call."}
  ]

  @doc """
  Classify an error message string into a `{category, subcategory, suggestion}` triple.

  Pattern-matching is applied in order; the first match wins.
  If no rule matches, returns `{:unknown_error, "unclassified", suggestion}`.
  """
  @spec classify(String.t()) :: classification()
  def classify(message) when is_binary(message) do
    Enum.find_value(@rules, default_classification(message), fn {pattern, cat, sub, hint} ->
      if Regex.match?(pattern, message) do
        {cat, sub, hint}
      end
    end)
  end

  def classify(_),
    do: {:unknown_error, "unclassified", "Inspect the error value for more context."}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp default_classification(message) do
    hint =
      if String.length(message) > 0 do
        "Error: #{String.slice(message, 0, 120)}. Add more specific handling for this case."
      else
        "An unknown error occurred. Enable debug logging for more context."
      end

    {:unknown_error, "unclassified", hint}
  end
end
