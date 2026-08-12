defmodule OptimalSystemAgent.OS.Shell do
  @moduledoc """
  Cross-platform shell invocation helper.

  On Unix (Linux/macOS) commands run through `sh -c "<command>"`, exactly as
  before. On Windows there is no `sh` on PATH, so commands run through the
  system command interpreter (`%COMSPEC%`, defaulting to `cmd`) with `/C`.

  This centralizes the OS branch so every call site (`shell_execute`, direct
  exec, host sandbox, hooks, verification, monitor, background tasks) behaves
  identically per-OS. The Unix path is byte-for-byte the previous behavior.
  """

  @doc """
  Returns `{executable, args}` for running `command` through the platform shell.

  Unix:    `{"sh", ["-c", command]}`
  Windows: `{comspec, ["/C", command]}`
  """
  @spec invocation(String.t()) :: {String.t(), [String.t()]}
  def invocation(command) when is_binary(command) do
    case :os.type() do
      {:win32, _} ->
        comspec = System.get_env("COMSPEC") || "cmd"
        {comspec, ["/C", command]}

      _ ->
        {"sh", ["-c", command]}
    end
  end

  @doc """
  Returns the shell executable path for `Port.open/2` `:spawn_executable`.

  Unix:    the resolved `sh` (falls back to `/bin/sh`).
  Windows: the resolved `%COMSPEC%` (falls back to `cmd`).
  """
  @spec executable() :: String.t()
  def executable do
    case :os.type() do
      {:win32, _} ->
        System.get_env("COMSPEC") || System.find_executable("cmd") || "cmd"

      _ ->
        System.find_executable("sh") || "/bin/sh"
    end
  end

  @doc """
  Returns the argument list (excluding the command string) for a
  `Port.open/2` `{:args, ...}` invocation of the platform shell.

  Unix:    `["-c"]`   → caller appends the command string.
  Windows: `["/C"]`   → caller appends the command string.
  """
  @spec port_flags() :: [String.t()]
  def port_flags do
    case :os.type() do
      {:win32, _} -> ["/C"]
      _ -> ["-c"]
    end
  end

  @doc """
  Drop-in replacement for `System.cmd("sh", ["-c", command], opts)` that is
  cross-platform.

  Every caller of this function hands it a whole command STRING that came from
  a model, a hook definition, a verification config or a workspace file — i.e.
  the exact shape that can contain `echo $ANTHROPIC_API_KEY`. So the `:env`
  option is always routed through `OptimalSystemAgent.OS.Env`, which unsets the
  secret-shaped variables and leaves `PATH`/`HOME`/toolchain vars alone.

  A caller-supplied `:env` is MERGED on top of the scrub rather than replacing
  it, so a call site that deliberately injects a value (hook payload vars) keeps
  working and can still force a credential through if it must.

  All other options are passed through unchanged.
  """
  @spec cmd(String.t(), keyword()) :: {Collectable.t(), non_neg_integer()}
  def cmd(command, opts \\ []) when is_binary(command) do
    {exe, args} = invocation(command)
    caller_env = Keyword.get(opts, :env, [])
    opts = Keyword.put(opts, :env, OptimalSystemAgent.OS.Env.cmd_env(caller_env))
    System.cmd(exe, args, opts)
  end
end
