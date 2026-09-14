# verify_snippets.exs — compile-check every Elixir code block in markdown files.
#
# Usage:
#   elixir verify_snippets.exs FILE.md [FILE2.md ...]
#
# Fence contract:
#   ```elixir        -> MUST compile with no errors AND no undefined-function warnings
#   ```elixir-run    -> MUST compile and EXECUTE without raising (script-style smoke run)
#   ```elixir-bad    -> MUST FAIL to compile (documented anti-pattern; passing = broken example)
#
# Exit code 0 = all fences satisfy their contract. Non-zero = list of failures.
#
# Notes:
# - Non-module blocks are wrapped in a throwaway module so both module-style and
#   script-style snippets compile the same way.
# - "Module.function/N is undefined" warnings are treated as FAILURES: that is
#   exactly the hallucinated-stdlib / dead-code failure mode this check exists for.
# - Other warnings (unused variable, etc.) are reported but do not fail.
#
# Run with the repository's matched Elixir/OTP pair (Elixir >= 1.17).
# Trusted author-written examples only: compilation and run fences execute code.

defmodule SnippetVerifier do
  defmodule Failure do
    defstruct [:file, :index, :kind, :detail]
  end

  def main(argv) do
    {oks, failures} =
      argv
      |> Enum.flat_map(fn path ->
        blocks = extract(File.read!(path))

        blocks
        |> Enum.with_index(1)
        |> Enum.map(fn {{kind, code}, i} -> check(kind, code, path, i) end)
      end)
      |> Enum.split_with(&(&1 == :ok))

    failures = Enum.filter(failures, &(&1 != :ok))
    report(oks, failures)
    if failures == [] and oks != [], do: 0, else: 1
  end

  defp extract(text) do
    Regex.scan(fence(), text)
    |> Enum.map(fn [_, kind, code] -> {kind, String.trim_trailing(code)} end)
  end

  defp fence, do: ~r/```(elixir(?:-run|-bad)?)[ \t]*\n(.*?)^```/sm

  defp check(kind, code, path, idx) do
    source = wrap(code, System.unique_integer([:positive]))
    {result, diagnostics} = run_isolated(source, String.contains?(kind, "run"))

    cond do
      String.contains?(kind, "bad") and (result == :error or undefined?(diagnostics)) ->
        :ok

      String.contains?(kind, "bad") ->
        %Failure{
          file: path,
          index: idx,
          kind: kind,
          detail:
            "BAD example COMPILED CLEAN — it does not demonstrate the failure it claims. Fix the example."
        }

      result == :error ->
        %Failure{file: path, index: idx, kind: kind, detail: "compile error:\n#{diagnostics}"}

      undefined?(diagnostics) ->
        %Failure{
          file: path,
          index: idx,
          kind: kind,
          detail: "undefined function warnings (hallucinated stdlib?):\n#{diagnostics}"
        }

      true ->
        :ok
    end
  end

  # Compiles `source` in a fresh process; for run-blocks also executes run/0.
  # Returns {:ok | :error, diagnostics_text}.
  defp run_isolated(source, should_run?) do
    owner = self()

    pid =
      spawn(fn ->
        try do
          {mods, warnings} = compile(source)

          if should_run? do
            Enum.each(mods, fn {m, _beam} ->
              if function_exported?(m, :run, 0), do: apply(m, :run, [])
            end)
          end

          send(owner, {:done, :ok, warnings})
        rescue
          e -> send(owner, {:done, :error, Exception.format(:error, e)})
        catch
          kind, value -> send(owner, {:done, :error, "#{kind}: #{inspect(value)}"})
        end
      end)

    ref = Process.monitor(pid)

    receive do
      {:done, status, text} ->
        Process.demonitor(ref, [:flush])
        {status, text}

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, "verifier process died: #{inspect(reason)}"}
    after
      15_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {:error, "timeout compiling snippet"}
    end
  end

  defp compile(source) do
    {result, diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source) end)

    warnings =
      diagnostics
      |> Enum.filter(&(&1.severity == :warning))
      |> Enum.map_join("\n", &"#{&1.message}")

    {result, warnings}
  end

  defp wrap(code, idx) do
    if Regex.match?(~r/^\s*defmodule\b/m, code) do
      code
    else
      """
      defmodule Snippet_#{idx} do
        def run do
          #{String.replace(code, "\n", "\n  ")}
        end
      end
      """
    end
  end

  defp undefined?(warnings),
    do:
      Regex.match?(
        ~r/is undefined (or private|\(module .+? is not available\)|, cannot define module)/,
        warnings
      )

  defp report(oks, failures) do
    total = length(oks) + length(failures)
    IO.puts("#{length(oks)}/#{total} snippets verified.")

    Enum.each(failures, fn %Failure{} = f ->
      IO.puts("\nFAIL #{f.file}##{f.index} [#{f.kind}]\n#{f.detail}")
    end)
  end
end

System.halt(SnippetVerifier.main(System.argv()))
