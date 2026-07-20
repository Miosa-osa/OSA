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

ExUnit.start(exclude: exclude_tags)
