# Exclude :integration tests (require live external services) and
# :linux_only tests (depend on Linux X11 tooling: xdotool, maim, slop)
# on non-Linux hosts.  Linux CI sets LINUX_X11_TESTS=1 to include them.
linux_x11_tests? = System.get_env("LINUX_X11_TESTS") == "1" or match?({:unix, :linux}, :os.type())

os_darwin? = match?({:unix, :darwin}, :os.type())
os_windows? = match?({:win32, _}, :os.type())

exclude_tags =
  [:integration] ++
    if(linux_x11_tests?, do: [], else: [:linux_only]) ++
    if(os_darwin?, do: [], else: [:macos, :macos_native]) ++
    if(os_windows?, do: [], else: [:windows_only])

# Start each suite run from a clean sticky-permission-mode store. The file is
# already isolated to a tmp path (config/test.exs), but unique() session ids
# reset per VM start and the tmp file persists across runs, so a stale
# "mode-38 -> overdrive" from a prior run could otherwise collide with a recycled
# id and make a fresh session read a non-:ask default. Removing it here makes the
# store empty at load, so collisions are impossible within or across runs.
case Application.get_env(:optimal_system_agent, :permission_mode_file) do
  path when is_binary(path) -> File.rm(path)
  _ -> :ok
end

# Same hazard, same fix, for the durable-execution step log. `durable_log_dir`
# is a single tmp directory (config/test.exs) shared by EVERY run, and
# `DurableLog.run_once/3` is an idempotency cache: a step whose
# {session_id, turn, iteration, tool, canonical args} key is already recorded
# returns the recorded result WITHOUT invoking the tool — so no telemetry, no
# `:tool_result` Bus event, no PubSub broadcast.
#
# Test session ids are routinely built from `System.unique_integer/1`, which
# restarts at a low number on every VM boot. A prior run therefore leaves
# `<tmp>/osa-test-durable/<recycled-id>.jsonl` on disk, and the next run's
# same-numbered session replays it instead of executing — turning any test that
# asserts on tool-execution side effects into a seed-dependent flake that still
# passes in isolation on a clean machine. Clearing the directory at suite start
# makes every key a guaranteed miss, so collisions are impossible across runs
# (within a run `unique_integer` is already monotonic).
case Application.get_env(:optimal_system_agent, :durable_log_dir) do
  dir when is_binary(dir) -> File.rm_rf(dir)
  _ -> :ok
end

ExUnit.start(exclude: exclude_tags)
