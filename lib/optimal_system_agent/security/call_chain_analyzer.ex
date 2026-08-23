defmodule OptimalSystemAgent.Security.CallChainAnalyzer do
  @moduledoc """
  Whitebox 0-day discovery by LLM-driven source-to-sink call-chain analysis.

  Adapted from Vulnhuntr's design (protectai/vulnhuntr) and Project Naptime /
  Big Sleep's "let the model walk the code" loop. OSA's pentest capability was
  blackbox (DAST) only - but OSA is a coding agent that usually HAS the target
  source, which is the strongest possible position to find a 0-day. This module
  is that whitebox pass.

  ## The loop

  1. **Seed** - start at an entry point (a route handler, a request parser, a
     deserializer) and ask the model: does this handle remote/user input, what
     are the input SOURCES, and which functions/methods does the tainted data
     flow into next?
  2. **Trace** - for each next symbol the model names, resolve its definition
     (via the injected `:reader`) and feed it back. Repeat until the model
     reaches a dangerous SINK (exec/query/deserialize/file-open/SSRF-capable
     call) or `:max_depth` is hit. This is the "reanalyze in a loop until the
     full call chain is mapped" step - a single-shot read cannot see a
     multi-file flow.
  3. **Judge** - with the complete chain in context, run a vuln-class-specific
     analysis prompt (`analysis_prompt/1`) that returns, per class: whether the
     flow is exploitable, the confidence, the concrete source and sink, a
     proof-of-concept, and a CVSS vector so the finding can be scored.

  ## Testability

  The LLM call and the file resolution are both injected (`:runner`, `:reader`),
  exactly like `GoalVerifier`'s panel runner, so the traversal logic is unit
  testable with stubs and no network. In production `:runner` is
  `Providers.chat/2` and `:reader` reads from the workspace.

  ## Authorization

  Whitebox analysis is read-only over source you already possess, so it is the
  safest offensive capability - it never touches a live target. It still records
  findings as security notes for the same review discipline as any other
  finding.
  """

  require Logger

  alias OptimalSystemAgent.Security.{Cvss, CweCatalog}

  @vuln_classes [
    :rce,
    :sqli,
    :ssrf,
    :idor,
    :xss,
    :lfi,
    :path_traversal,
    :xxe,
    :ssti,
    :deserialization
  ]

  @default_max_depth 6
  @default_max_findings 25

  @type finding :: %{
          vuln_class: atom(),
          exploitable: boolean(),
          confidence: :high | :medium | :low,
          source: String.t(),
          sink: String.t(),
          call_chain: [String.t()],
          reasoning: String.t(),
          poc: String.t(),
          cvss_vector: String.t() | nil,
          cvss_score: float() | nil,
          severity: atom() | nil,
          cwe: String.t() | nil,
          owasp: String.t() | nil
        }

  @doc "The vulnerability classes this analyzer hunts for."
  @spec vuln_classes() :: [atom()]
  def vuln_classes, do: @vuln_classes

  @doc """
  Analyze one entry point and return validated findings.

  ## Options

    * `:entry` - path label for the entry file (for the call chain trace)
    * `:content` - the entry file's source (required)
    * `:vuln_classes` - subset of `vuln_classes/0` to hunt (default: all)
    * `:reader` - `fn symbol_or_path -> {:ok, source} | :not_found end`, resolves
      a symbol/file the model asks to see next. Defaults to "not found" (so a
      caller that passes no reader gets a single-file analysis).
    * `:runner` - `fn messages -> {:ok, text} | {:error, reason}`, the LLM call.
    * `:max_depth` - call-chain hops before the trace stops (default #{@default_max_depth}).

  Returns `{:ok, [finding]}`. Findings are only those the judge marked
  exploitable; each carries a CVSS score when the judge supplied a vector.
  """
  @spec analyze(keyword()) :: {:ok, [finding()]} | {:error, String.t()}
  def analyze(opts) do
    content = Keyword.get(opts, :content)

    if not is_binary(content) or content == "" do
      {:error, "content is required"}
    else
      classes = Keyword.get(opts, :vuln_classes, @vuln_classes)
      reader = Keyword.get(opts, :reader, fn _ -> :not_found end)
      runner = Keyword.get(opts, :runner) || default_runner()
      max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
      entry = Keyword.get(opts, :entry, "<entry>")

      chain = trace(entry, content, reader, runner, max_depth)
      {:ok, judge(chain, classes, runner)}
    end
  end

  # ── trace: walk source -> sink across files ────────────────────────────────

  # Accumulates the visited symbols and their source into a context the judge
  # sees. Stops at max_depth or when the model names no further symbols.
  defp trace(entry, content, reader, runner, max_depth) do
    do_trace([{entry, content}], MapSet.new([entry]), reader, runner, max_depth)
  end

  defp do_trace(acc, _seen, _reader, _runner, 0), do: Enum.reverse(acc)

  defp do_trace([{label, source} | _] = acc, seen, reader, runner, depth) do
    case ask_next_symbols(label, source, runner) do
      [] ->
        Enum.reverse(acc)

      symbols ->
        {new_acc, new_seen} =
          symbols
          |> Enum.reject(&MapSet.member?(seen, &1))
          |> Enum.reduce({acc, seen}, fn sym, {a, s} ->
            case reader.(sym) do
              {:ok, src} -> {[{sym, src} | a], MapSet.put(s, sym)}
              _ -> {a, MapSet.put(s, sym)}
            end
          end)

        if length(new_acc) == length(acc) do
          Enum.reverse(new_acc)
        else
          do_trace(new_acc, new_seen, reader, runner, depth - 1)
        end
    end
  end

  defp ask_next_symbols(label, source, runner) do
    messages = [
      %{role: "system", content: trace_system_prompt()},
      %{role: "user", content: "FILE: #{label}\n\n```\n#{cap(source)}\n```"}
    ]

    with {:ok, text} <- runner.(messages),
         {:ok, %{"next_symbols" => syms}} when is_list(syms) <- extract_json(text) do
      syms |> Enum.filter(&is_binary/1) |> Enum.take(8)
    else
      _ -> []
    end
  end

  # ── judge: vuln-class-specific exploitability analysis ──────────────────────

  defp judge(chain, classes, runner) do
    context = render_chain(chain)

    classes
    |> Enum.take(@default_max_findings)
    |> Enum.map(fn class -> judge_one(class, context, runner) end)
    |> Enum.filter(& &1)
    |> Enum.filter(& &1.exploitable)
  end

  defp judge_one(class, context, runner) do
    messages = [
      %{role: "system", content: analysis_prompt(class)},
      %{role: "user", content: context}
    ]

    with {:ok, text} <- runner.(messages),
         {:ok, json} when is_map(json) <- extract_json(text) do
      build_finding(class, json)
    else
      _ -> nil
    end
  end

  defp build_finding(class, json) do
    exploitable = json["exploitable"] == true
    vector = json["cvss_vector"]

    {cvss_score, severity} =
      case vector && Cvss.score(vector) do
        {:ok, %{base_score: s, severity: sev}} -> {s, sev}
        _ -> {nil, nil}
      end

    catalog = CweCatalog.lookup(class)

    %{
      vuln_class: class,
      exploitable: exploitable,
      confidence: confidence(json["confidence"]),
      source: to_s(json["source"]),
      sink: to_s(json["sink"]),
      call_chain: (is_list(json["call_chain"]) && json["call_chain"]) || [],
      reasoning: to_s(json["reasoning"]),
      poc: to_s(json["poc"]),
      cvss_vector: vector,
      cvss_score: cvss_score,
      severity: severity,
      cwe: catalog && catalog.cwe,
      owasp: catalog && catalog.owasp
    }
  end

  # ── prompts ─────────────────────────────────────────────────────────────

  @doc false
  def trace_system_prompt do
    """
    You are a security code auditor mapping how UNTRUSTED user input flows
    through a codebase toward dangerous operations. You are given one file.

    Identify where remote/user-controlled data ENTERS (request params, bodies,
    headers, uploaded files, deserialized data) and which functions, methods, or
    classes that tainted data is then passed INTO - the next hop in the call
    chain. Name symbols precisely enough to look them up (function or method
    name, or file path).

    Reply with ONE JSON object and nothing else:

        {"handles_user_input": true|false,
         "input_sources": ["<where untrusted data enters>"],
         "next_symbols": ["<function/method/file to follow the taint into>"]}

    If the file neither takes user input nor forwards data anywhere interesting,
    return empty arrays. Do not speculate about symbols you cannot see.
    """
  end

  @doc """
  The vuln-class-specific analysis (judge) system prompt. Public so the exact
  contract per class is testable and reviewable.
  """
  @spec analysis_prompt(atom()) :: String.t()
  def analysis_prompt(class) do
    """
    You are an adversarial security auditor. Below is a call chain assembled
    from one or more source files: an untrusted-input SOURCE and the code the
    data flows through. Judge ONLY whether a #{class_label(class)}
    (#{class_focus(class)}) vulnerability is concretely exploitable along this
    chain.

    Refute your own hunch: only mark exploitable when you can name the exact
    source, the exact sink, and a payload that reaches it WITHOUT being
    neutralized by validation/encoding/parameterization you can actually see in
    the code. Missing sanitization you cannot see is NOT evidence - default to
    exploitable=false when uncertain.

    Reply with ONE JSON object and nothing else:

        {"exploitable": true|false,
         "confidence": "high"|"medium"|"low",
         "source": "<file:symbol where the tainted input enters>",
         "sink": "<file:symbol of the dangerous operation>",
         "call_chain": ["<hop>", "..."],
         "reasoning": "<why it is or is not exploitable, citing the code>",
         "poc": "<a concrete proof-of-concept request/input, or empty>",
         "cvss_vector": "CVSS:3.1/AV:.../AC:.../PR:.../UI:.../S:.../C:.../I:.../A:..."}

    The cvss_vector is required when exploitable is true; omit it otherwise.
    """
  end

  defp class_label(:rce), do: "Remote Code Execution"
  defp class_label(:sqli), do: "SQL Injection"
  defp class_label(:ssrf), do: "Server-Side Request Forgery"
  defp class_label(:idor), do: "Insecure Direct Object Reference"
  defp class_label(:xss), do: "Cross-Site Scripting"
  defp class_label(:lfi), do: "Local File Inclusion"
  defp class_label(:path_traversal), do: "Path Traversal"
  defp class_label(:xxe), do: "XML External Entity"
  defp class_label(:ssti), do: "Server-Side Template Injection"
  defp class_label(:deserialization), do: "Insecure Deserialization"
  defp class_label(other), do: to_string(other)

  defp class_focus(:rce), do: "user input reaching exec/eval/system/spawn"
  defp class_focus(:sqli), do: "user input concatenated into a SQL query"
  defp class_focus(:ssrf), do: "user input controlling an outbound request URL/host"

  defp class_focus(:idor),
    do: "a user-supplied id used to access an object without an ownership check"

  defp class_focus(:xss), do: "user input reflected into HTML/JS without encoding"
  defp class_focus(:lfi), do: "user input selecting a file to include/read"

  defp class_focus(:path_traversal),
    do: "user input in a filesystem path without canonicalization"

  defp class_focus(:xxe), do: "user-controlled XML parsed with external entities enabled"
  defp class_focus(:ssti), do: "user input rendered as a template expression"
  defp class_focus(:deserialization), do: "user input deserialized into objects"
  defp class_focus(_), do: "untrusted input reaching a dangerous operation"

  # ── helpers ─────────────────────────────────────────────────────────────

  defp render_chain(chain) do
    chain
    |> Enum.map(fn {label, src} -> "=== #{label} ===\n#{cap(src)}" end)
    |> Enum.join("\n\n")
  end

  @cap_bytes 24_000
  defp cap(s) when byte_size(s) > @cap_bytes,
    do: binary_part(s, 0, @cap_bytes) <> "\n… [truncated]"

  defp cap(s), do: s

  defp confidence("high"), do: :high
  defp confidence("low"), do: :low
  defp confidence(_), do: :medium

  defp to_s(v) when is_binary(v), do: v
  defp to_s(nil), do: ""
  defp to_s(v), do: inspect(v)

  defp extract_json(text) when is_binary(text) do
    # Tolerate a fenced block or leading prose: grab the first {...} span.
    with [_ | _] = _ <- [text],
         %{"start" => s, "len" => l} <- json_span(text),
         candidate <- binary_part(text, s, l),
         {:ok, decoded} <- Jason.decode(candidate) do
      {:ok, decoded}
    else
      _ ->
        case Jason.decode(text) do
          {:ok, m} -> {:ok, m}
          _ -> :error
        end
    end
  end

  defp extract_json(_), do: :error

  defp json_span(text) do
    case :binary.match(text, "{") do
      {start, _} ->
        # last closing brace
        case last_brace(text) do
          nil -> nil
          stop when stop >= start -> %{"start" => start, "len" => stop - start + 1}
          _ -> nil
        end

      :nomatch ->
        nil
    end
  end

  defp last_brace(text) do
    case :binary.matches(text, "}") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp default_runner do
    fn messages ->
      case OptimalSystemAgent.Providers.Registry.chat(messages,
             max_tokens: 1500,
             temperature: 0.0
           ) do
        {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
        {:error, reason} -> {:error, inspect(reason)}
        other -> {:error, inspect(other)}
      end
    end
  end
end
