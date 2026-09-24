# Loads every module under lib/ and runs every test under test/.
# Exit status 0 means every test passed.
ExUnit.start(autorun: false)

root = Path.expand("..", __DIR__)

lib_files = root |> Path.join("lib/**/*.ex") |> Path.wildcard() |> Enum.sort()

case Kernel.ParallelCompiler.compile(lib_files, return_diagnostics: true) do
  {:ok, _modules, _diagnostics} -> :ok
  {:error, _errors, _diagnostics} -> System.halt(2)
end

root
|> Path.join("test/**/*_test.exs")
|> Path.wildcard()
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

%{failures: failures} = ExUnit.run()
System.halt(if failures == 0, do: 0, else: 1)
