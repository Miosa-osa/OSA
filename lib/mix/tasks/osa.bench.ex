defmodule Mix.Tasks.Osa.Bench do
  @shortdoc "Run OSA's efficiency benchmark (real coding tasks, timed and checked)"

  @moduledoc """
  Runs the task suite in `bench/osabench/tasks` against scratch copies of the
  fixture repo and scores every run: wall time, model time, tool time, tokens,
  cost, tool calls, retries, wasted steps, and a deterministic pass/fail.

      mix osa.bench                                   # configured provider/model
      mix osa.bench --provider ollama_cloud --model glm-5.2:cloud
      mix osa.bench --only settings-one-line,fix-failing-test --repeat 3
      mix osa.bench --category search
      mix osa.bench --list

      # controls: replay each task's reference solution (must all pass) or do
      # nothing (must all fail) through the real loop and tools, no model
      MIX_ENV=test mix osa.bench --control oracle
      MIX_ENV=test mix osa.bench --control nop

      # drive a running daemon (e.g. the installed release) over HTTP
      mix osa.bench --url http://127.0.0.1:8089 --token $OSA_API_TOKEN

      # before/after
      mix osa.bench --compare before.json after.json

  ## Options

    * `--provider`, `--model` - override the configured provider/model
    * `--only a,b` / `--category c` - select tasks
    * `--repeat N` - attempts per task (medians are reported)
    * `--timeout S` - per-task limit in seconds (default 600)
    * `--out PATH` - result file (default `bench/osabench/runs/<run_id>.json`)
    * `--control oracle|nop` - scripted controls (mock provider; `MIX_ENV=test`)
    * `--url URL`, `--token T` - HTTP runner against a live daemon
    * `--keep` - keep workspaces and bench sessions for inspection
    * `--root DIR` - tasks + fixtures directory (default `bench/osabench`)
    * `--compare A B` - print a before/after table for two result files;
      `--fail-on-regression` exits 1 when a task went from pass to fail
  """

  use Mix.Task

  alias OptimalSystemAgent.Bench
  alias OptimalSystemAgent.Bench.{Report, TaskSpec}

  @switches [
    provider: :string,
    model: :string,
    only: :string,
    category: :string,
    repeat: :integer,
    timeout: :integer,
    out: :string,
    control: :string,
    url: :string,
    token: :string,
    keep: :boolean,
    root: :string,
    list: :boolean,
    compare: :boolean,
    fail_on_regression: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("unknown option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    cond do
      opts[:compare] -> compare(args, opts)
      opts[:list] -> list(opts)
      true -> bench(opts)
    end
  end

  # ── compare ──────────────────────────────────────────────────────────

  defp compare([a, b], opts) do
    with {:ok, da} <- Report.read(a),
         {:ok, db} <- Report.read(b) do
      result = Report.compare(da, db)
      Mix.shell().info(result.text)

      if opts[:fail_on_regression] and result.summary.regressed != [] do
        exit({:shutdown, 1})
      end
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp compare(_, _), do: Mix.raise("--compare takes exactly two result files")

  # ── list ─────────────────────────────────────────────────────────────

  defp list(opts) do
    root = opts[:root] || Bench.default_root()

    case TaskSpec.load_dir(Path.join(root, "tasks")) do
      {:ok, tasks} ->
        width = tasks |> Enum.map(&String.length(&1.id)) |> Enum.max(fn -> 4 end)

        Enum.each(tasks, fn t ->
          Mix.shell().info(
            String.pad_trailing(t.id, width) <>
              "  " <> String.pad_trailing(t.category, 9) <> " " <> (t.title || "")
          )
        end)

        Mix.shell().info("\n#{length(tasks)} tasks")

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  # ── run ──────────────────────────────────────────────────────────────

  defp bench(opts) do
    control = control(opts[:control])
    runner = if opts[:url], do: :http, else: :in_process

    # The HTTP runner only needs this BEAM for its HTTP client and the task
    # files; the in-process runner needs the whole agent.
    if runner == :http do
      Mix.Task.run("app.config")
    else
      use_private_http_port()
      Mix.Task.run("app.start")
    end

    if runner == :http, do: Application.ensure_all_started(:req)
    # After boot: starting the app re-applies the configured level.
    Logger.configure(level: :error)

    provider =
      cond do
        control != nil -> ensure_mock!()
        true -> opts[:provider]
      end

    run_opts =
      [
        root: opts[:root],
        provider: provider,
        model: if(control, do: "mock-model-1.0", else: opts[:model]),
        control: control,
        only: split(opts[:only]),
        categories: split(opts[:category]),
        repeat: opts[:repeat] || 1,
        timeout_s: opts[:timeout] || 600,
        runner: runner,
        url: opts[:url],
        token: opts[:token] || System.get_env("OSA_API_TOKEN"),
        shared_secret: System.get_env("OSA_SHARED_SECRET"),
        keep_workspace: opts[:keep] || false,
        keep_sessions: opts[:keep] || false,
        on_result: &progress/1
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Bench.run(run_opts) do
      {:ok, doc} ->
        out =
          opts[:out] ||
            Path.join([opts[:root] || Bench.default_root(), "runs", "#{doc.run_id}.json"])

        Report.write!(out, doc)
        Mix.shell().info("\n" <> Report.table(doc.tasks))
        Mix.shell().info("\nresults: #{out}")

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp progress(row) do
    ok = if row.pass, do: "pass", else: "FAIL"
    secs = OptimalSystemAgent.Agent.TurnTrace.secs(row.wall_ms || 0)
    Mix.shell().info("  #{ok}  #{row.id}##{row.attempt}  #{secs}")
  end

  # The in-process runner boots a full agent, HTTP listener included. The
  # operator's own daemon normally holds the default port, and a bench run must
  # neither fail on that nor answer that daemon's clients - bind a free port.
  defp use_private_http_port do
    if System.get_env("OSA_HTTP_PORT") in [nil, ""] and System.get_env("OSA_PORT") in [nil, ""] do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)
      System.put_env("OSA_HTTP_PORT", Integer.to_string(port))
    end
  end

  defp control(nil), do: nil
  defp control("oracle"), do: :oracle
  defp control("nop"), do: :nop
  defp control(other), do: Mix.raise("--control must be oracle or nop, got #{inspect(other)}")

  # Controls replay through the test mock provider, which is compiled only in
  # the test environment - it must never be routable in a real daemon.
  defp ensure_mock! do
    if Code.ensure_loaded?(OptimalSystemAgent.Test.MockProvider) do
      Application.put_env(:optimal_system_agent, :default_provider, :mock)
      :mock
    else
      Mix.raise(
        "--control replays through the mock provider, which only exists in the test build: " <>
          "run MIX_ENV=test mix osa.bench --control #{"oracle|nop"}"
      )
    end
  end

  defp split(nil), do: []
  defp split(s), do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
