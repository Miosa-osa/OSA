defmodule OptimalSystemAgent.Security.DefenseLab do
  @moduledoc """
  Reproducible defensive control experiments on disposable local Docker targets.
  Only bundled scenarios execute. No host execution fallback, external targets,
  bind mounts, published ports, image pulls, or privileged container operations.
  Evidence concerns the lab fixtures and embedded detectors, not a production SIEM.
  """
  @image "python:3.12-slim"
  @scenarios ~w(sql_injection path_traversal auth_rate_limit)

  def scenarios do
    %{
      image: @image,
      prerequisites: ["Docker daemon", "preinstalled #{@image}"],
      scenarios: [
        %{id: "sql_injection", control: "SQLite parameter binding", cwe: "CWE-89"},
        %{id: "path_traversal", control: "Canonical path containment", cwe: "CWE-22"},
        %{id: "auth_rate_limit", control: "Per-account failed-login limit", cwe: "CWE-307"}
      ],
      limitations: "Synthetic local targets and embedded detectors; no production coverage claim."
    }
  end

  def run(args, opts \\ [])

  def run(args, opts) when is_map(args) do
    scenario = Map.get(args, "scenario", "all")
    remediation = Map.get(args, "remediation", "apply")
    timeout = Map.get(args, "timeout_seconds", 30)
    runner = Keyword.get(opts, :runner, &command/2)

    cond do
      scenario not in ["all" | @scenarios] ->
        error("invalid_scenario", "Select an entry from scenarios")

      remediation not in ~w(apply none ineffective) ->
        error("invalid_remediation", "Use apply, none, or ineffective")

      not is_integer(timeout) or timeout < 5 or timeout > 60 ->
        error("invalid_timeout", "timeout_seconds must be 5..60")

      true ->
        execute(scenario, remediation, timeout, runner)
    end
  end

  def run(_, _), do: error("invalid_input", "Expected an object")

  defp execute(scenario, remediation, timeout, runner) do
    with {:ok, _, 0} <- runner.(["image", "inspect", @image], 5_000) do
      name = "osa-defense-" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

      owner = self()
      guardian = spawn(fn -> guard_cleanup(owner, name, timeout, runner) end)

      result =
        try do
          runner.(docker_args(name, scenario, remediation), timeout * 1_000)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end

      cleanup = runner.(["rm", "-f", name], 5_000)
      send(guardian, {:finished, owner})

      case {result, cleanup_ok?(cleanup)} do
        {{:ok, output, 0}, true} ->
          case Jason.decode(output) do
            {:ok, report} when is_map(report) ->
              if valid_report?(report, scenario) do
                {:ok,
                 Map.merge(report, %{
                   "container" => name,
                   "image" => @image,
                   "cleanup" => "confirmed",
                   "isolation" => "network=none; nonroot; no host mounts; read-only rootfs",
                   "evidence_json" => output,
                   "evidence_sha256" =>
                     Base.encode16(:crypto.hash(:sha256, output), case: :lower),
                   "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                 })}
              else
                error("invalid_evidence", "Lab evidence was incomplete or inconsistent")
              end

            _ ->
              error("invalid_evidence", "Lab process did not emit a valid evidence report")
          end

        {_, false} ->
          error("cleanup_failed", "Unable to confirm container removal: #{name}")

        {{:error, reason}, true} ->
          error("execution_failed", reason)

        {{:ok, output, code}, true} ->
          error("scenario_failed", "Exit #{code}: #{String.slice(output, 0, 2000)}")
      end
    else
      _ ->
        error(
          "prerequisite_missing",
          "Docker must be running and #{@image} preinstalled; no host fallback or automatic pull"
        )
    end
  end

  defp guard_cleanup(owner, name, timeout, runner) do
    monitor = Process.monitor(owner)

    receive do
      {:finished, ^owner} -> Process.demonitor(monitor, [:flush])
      {:DOWN, ^monitor, :process, ^owner, _} -> runner.(["rm", "-f", name], 5_000)
    after
      (timeout + 15) * 1_000 ->
        Process.demonitor(monitor, [:flush])
        runner.(["rm", "-f", name], 5_000)
    end
  end

  defp valid_report?(report, scenario) do
    expected = if scenario == "all", do: @scenarios, else: [scenario]
    results = report["scenarios"]

    is_list(results) and length(results) == length(expected) and
      Enum.all?(results, &is_map/1) and
      Enum.sort(Enum.map(results, & &1["scenario"])) == Enum.sort(expected) and
      Enum.all?(results, &valid_result?/1) and
      report["verified"] == Enum.all?(results, & &1["verified"])
  end

  defp valid_result?(%{"phases" => [before, after_phase], "verified" => verified})
       when is_map(before) and is_map(after_phase) and is_boolean(verified) do
    valid_phase?(before, "baseline") and valid_phase?(after_phase, "retest") and
      verified ==
        (before["attack_succeeded"] and before["benign_control_passed"] and
           not after_phase["attack_succeeded"] and after_phase["benign_control_passed"] and
           after_phase["alerts"] > 0 and after_phase["false_alerts"] == 0)
  end

  defp valid_result?(_), do: false

  defp valid_phase?(phase, name) do
    events = phase["events"]

    phase["phase"] == name and is_boolean(phase["attack_succeeded"]) and
      is_boolean(phase["benign_control_passed"]) and is_list(events) and events != [] and
      Enum.all?(events, fn event ->
        is_map(event) and
          Enum.all?(~w(expected_attack allowed alert), &is_boolean(event[&1]))
      end) and
      phase["alerts"] == Enum.count(events, & &1["alert"]) and
      phase["false_alerts"] == Enum.count(events, &(&1["alert"] and not &1["expected_attack"])) and
      phase["gaps"] ==
        if(phase["attack_succeeded"], do: ["attack_not_prevented"], else: []) ++
          if phase["alerts"] == 0, do: ["attack_not_detected"], else: []
  end

  defp cleanup_ok?({:ok, _, 0}), do: true
  defp cleanup_ok?({:ok, output, _}), do: String.contains?(output, "No such container")
  defp cleanup_ok?(_), do: false
  defp error(code, message), do: {:error, %{code: code, message: message}}

  @doc false
  def docker_args(name, scenario, remediation) do
    [
      "run",
      "--name",
      name,
      "--rm",
      "--pull=never",
      "--network=none",
      "--read-only",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--user=65534:65534",
      "--memory=128m",
      "--memory-swap=128m",
      "--cpus=0.5",
      "--pids-limit=32",
      "--tmpfs=/tmp:rw,noexec,nosuid,size=8m,mode=1777",
      @image,
      "python3",
      "-I",
      "-c",
      script(),
      scenario,
      remediation
    ]
  end

  # A port allows a bounded wait and output ceiling without a linked Task whose
  # exit could crash the tool caller. Docker rm -f handles a timed-out target.
  defp command(args, timeout) do
    case System.find_executable("docker") do
      nil ->
        {:error, "Docker executable not found"}

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        collect(port, System.monotonic_time(:millisecond) + timeout, "")
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp collect(port, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} ->
        if byte_size(output) + byte_size(bytes) > 100_000 do
          Port.close(port)
          {:error, "Output limit exceeded"}
        else
          collect(port, deadline, output <> bytes)
        end

      {^port, {:exit_status, code}} ->
        {:ok, output, code}
    after
      remaining ->
        Port.close(port)
        {:error, "Execution timed out"}
    end
  end

  @doc false
  def script do
    ~S'''
    import json, sqlite3, pathlib, tempfile, sys
    scenario, remediation = sys.argv[1:3]

    def sql(mode):
        fixed = mode == 'apply'
        db = sqlite3.connect(':memory:')
        db.execute('create table users (name text, password text)')
        db.execute('insert into users values (?, ?)', ('alice', 'correct'))
        events = []
        def login(name, password, expected_attack=False):
            if mode == 'ineffective': name = name.strip()
            suspicious = "' or " in name.lower()
            try:
                rows = db.execute('select name from users where name=? and password=?', (name, password)).fetchall() if fixed else db.execute("select name from users where name='%s' and password='%s'" % (name, password)).fetchall()
            except sqlite3.OperationalError:
                rows = []
            events.append({'event':'login', 'expected_attack':expected_attack, 'suspicious':suspicious, 'allowed':bool(rows), 'alert': fixed and suspicious})
            return bool(rows)
        attack = login("' OR 1=1 --", 'wrong', True)
        benign = login('alice', 'correct')
        wrong_rejected = not login('alice', 'wrong')
        punctuation_rejected = not login("o'connor", 'wrong')
        db.close()
        return attack, benign and wrong_rejected and punctuation_rejected, events

    def traversal(mode):
        fixed = mode == 'apply'
        events = []
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / 'public'; root.mkdir()
            (root / 'readme.txt').write_text('public example')
            (pathlib.Path(tmp) / 'secret.txt').write_text('LAB_SECRET')
            def read(name, expected_attack=False):
                if mode == 'ineffective': name = name.lstrip('/')
                path = (root / name).resolve()
                suspicious = not path.is_relative_to(root)
                blocked = fixed and suspicious
                data = None if blocked else path.read_text()
                events.append({'event':'file_read', 'expected_attack':expected_attack, 'path':name, 'suspicious':suspicious, 'allowed':not blocked, 'alert':fixed and suspicious})
                return data
            attack = read('../secret.txt', True) == 'LAB_SECRET'
            benign = read('readme.txt') == 'public example'
        return attack, benign, events

    def auth(mode):
        fixed = mode == 'apply'
        failures, events = {}, []
        def login(account, password, expected_attack=False):
            count = failures.get(account, 0)
            blocked = (fixed and count >= 3) or (mode == 'ineffective' and count >= 1000)
            allowed = not blocked and password == 'correct'
            if not allowed: failures[account] = count + 1
            events.append({'event':'login', 'expected_attack':expected_attack, 'account':account, 'attempt':count + 1, 'suspicious':count >= 3, 'allowed':allowed, 'alert':fixed and count >= 3})
            return allowed
        for _ in range(3): login('target', 'wrong', True)
        attack = login('target', 'correct', True)
        benign = login('other_account', 'correct')
        return attack, benign, events

    catalog = {
     'sql_injection': (sql, 'Use parameterized SQL and flag malformed login input.', 'Restore the prior query implementation only inside a new disposable lab.'),
     'path_traversal': (traversal, 'Resolve paths and require containment under the public root.', 'Remove the containment check only inside a new disposable lab.'),
     'auth_rate_limit': (auth, 'Block the fourth attempt after three failures per account; alert on blocked attempts.', 'Reset the temporary in-memory counter; production needs expiry and recovery design.')
    }
    results = []
    for name in (list(catalog) if scenario == 'all' else [scenario]):
        fn, patch, rollback = catalog[name]
        phases = []
        for phase, mode in [('baseline', 'none'), ('retest', remediation)]:
            attack, benign, events = fn(mode)
            alerts = sum(1 for e in events if e['alert'])
            false_alerts = sum(1 for e in events if e['alert'] and not e['expected_attack'])
            phases.append({'phase':phase, 'attack_succeeded':attack, 'benign_control_passed':benign,
              'alerts':alerts, 'false_alerts':false_alerts, 'events':events,
              'gaps':(['attack_not_prevented'] if attack else []) + (['attack_not_detected'] if alerts == 0 else [])})
        before, after = phases
        verified = before['attack_succeeded'] and before['benign_control_passed'] and not after['attack_succeeded'] and after['benign_control_passed'] and after['alerts'] > 0 and after['false_alerts'] == 0
        applied_change = patch if remediation == 'apply' else ('No change' if remediation == 'none' else {'sql_injection':'Trim whitespace only (does not parameterize SQL)', 'path_traversal':'Strip leading slash only (does not block parent traversal)', 'auth_rate_limit':'Set an ineffective 1000-attempt threshold'}[name])
        results.append({'scenario':name, 'phases':phases, 'remediation':{'mode':remediation, 'change':applied_change, 'recommended_change':patch, 'rollback':rollback}, 'verified':verified})
    print(json.dumps({'schema_version':1, 'scope':'bundled synthetic lab targets and embedded detectors only',
     'scenarios':results, 'verified':all(r['verified'] for r in results)}))
    '''
  end
end
