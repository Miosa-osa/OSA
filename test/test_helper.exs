# Exclude :integration tests (require live external services) and
# :linux_only tests (depend on Linux X11 tooling: xdotool, maim, slop)
# on non-Linux hosts.  Linux CI sets LINUX_X11_TESTS=1 to include them.
linux_x11_tests? = System.get_env("LINUX_X11_TESTS") == "1" or match?({:unix, :linux}, :os.type())

exclude_tags = [:integration] ++ if(linux_x11_tests?, do: [], else: [:linux_only])

ExUnit.start(exclude: exclude_tags)
