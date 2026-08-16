defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxWayland do
  @moduledoc """
  Linux Wayland adapter.

  Screenshots use `grim`; the clipboard uses `wl-copy`/`wl-paste`; the keyboard
  uses `wtype` (preferred) or `ydotool`; the pointer uses `ydotool` (needs the
  `ydotoold` daemon). The accessibility tree is delegated to the X11 adapter's
  AT-SPI2 helper, which is display-server independent.

  Actions Wayland has no portable tool for (global cursor query, window focus)
  are simply not implemented, so the Server reports them as unsupported.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  require Logger

  alias OptimalSystemAgent.Tools.BoundedCmd
  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.AppAllowlist
  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxX11

  @wtype_mods %{
    "ctrl" => "ctrl",
    "control" => "ctrl",
    "alt" => "alt",
    "option" => "alt",
    "shift" => "shift",
    "cmd" => "logo",
    "command" => "logo",
    "super" => "logo"
  }

  @wtype_keys %{
    "enter" => "Return",
    "return" => "Return",
    "tab" => "Tab",
    "space" => "space",
    "esc" => "Escape",
    "escape" => "Escape",
    "backspace" => "BackSpace",
    "delete" => "Delete",
    "up" => "Up",
    "down" => "Down",
    "left" => "Left",
    "right" => "Right",
    "home" => "Home",
    "end" => "End",
    "pageup" => "Prior",
    "pagedown" => "Next"
  }

  # ── Base behaviour callbacks ─────────────────────────────────────────

  @impl true
  def available? do
    has?("grim") and (has?("wtype") or has?("ydotool"))
  end

  @impl true
  def screenshot(opts \\ %{}) do
    dir = Path.expand("~/.osa/screenshots")
    File.mkdir_p!(dir)
    path = Path.join(dir, "screenshot_#{System.system_time(:millisecond)}.png")

    args =
      case region(opts) do
        %{"x" => x, "y" => y, "width" => w, "height" => h} ->
          ["-g", "#{x},#{y} #{w}x#{h}", path]

        _ ->
          [path]
      end

    case run("grim", args, "Screenshot") do
      :ok -> {:ok, path}
      {:error, _} = err -> err
    end
  end

  @impl true
  def click(x, y), do: pointer_click(x, y, "0xC0", "Click")

  @impl true
  def double_click(x, y) do
    with :ok <- pointer_click(x, y, "0xC0", "Double click") do
      run("ydotool", ["click", "0xC0"], "Double click")
    end
  end

  @impl true
  def type_text(text) do
    cond do
      has?("wtype") -> run("wtype", ["--", text], "Type")
      has?("ydotool") -> run("ydotool", ["type", "--", text], "Type")
      true -> {:error, "no Wayland typing tool found (install wtype or ydotool)"}
    end
  end

  @impl true
  def key_press(combo) do
    cond do
      has?("wtype") -> run("wtype", wtype_key_args(combo), "Key press")
      has?("ydotool") -> run("ydotool", ["key", combo], "Key press")
      true -> {:error, "no Wayland key tool found (install wtype or ydotool)"}
    end
  end

  @impl true
  def scroll(_direction, _amount),
    do:
      {:error,
       "scroll is not supported by the Wayland ydotool backend; use key pagedown / pageup"}

  @impl true
  def move_mouse(x, y),
    do: run("ydotool", ["mousemove", "--absolute", "-x", "#{x}", "-y", "#{y}"], "Move mouse")

  @impl true
  def drag(fx, fy, tx, ty) do
    with :ok <- move_mouse(fx, fy),
         :ok <- run("ydotool", ["click", "0x40"], "Drag press"),
         :ok <- move_mouse(tx, ty) do
      run("ydotool", ["click", "0x80"], "Drag release")
    end
  end

  @impl true
  def get_tree, do: LinuxX11.get_tree()

  # ── Extended callbacks (Server guards with function_exported?/3) ─────

  def right_click(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y),
    do: pointer_click(x, y, "0xC1", "Right click")

  def right_click(_), do: {:error, "right_click on Wayland requires x,y coordinates"}

  def middle_click(x, y), do: pointer_click(x, y, "0xC2", "Middle click")

  def triple_click(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y) do
    with :ok <- pointer_click(x, y, "0xC0", "Triple click"),
         :ok <- run("ydotool", ["click", "0xC0"], "Triple click") do
      run("ydotool", ["click", "0xC0"], "Triple click")
    end
  end

  def triple_click(_), do: {:error, "triple_click on Wayland requires x,y coordinates"}

  def left_mouse_down(x, y) do
    with :ok <- move_mouse(x, y) do
      run("ydotool", ["click", "0x40"], "Mouse down")
    end
  end

  def left_mouse_up(x, y) do
    with :ok <- move_mouse(x, y) do
      run("ydotool", ["click", "0x80"], "Mouse up")
    end
  end

  def hold_key(combo, duration) do
    # Best-effort: wtype has no press-and-hold and ydotool needs raw keycodes,
    # so we press the combo once and sleep for the requested duration.
    with :ok <- key_press(combo) do
      Process.sleep(trunc(max(0, min(duration || 1, 30)) * 1000))
      :ok
    end
  end

  def wait(seconds) do
    Process.sleep(trunc(max(0, min(seconds || 1, 30)) * 1000))
    :ok
  end

  def launch(app) when is_binary(app) do
    if AppAllowlist.allowed?(app) do
      # unbounded: deliberate — see LinuxX11.launch/1. This is a LAUNCH, not a
      # query; a deadline would kill the application the operator asked for.
      # Nothing waits on the result, so it cannot wedge a turn.
      _ = spawn(fn -> System.cmd("nohup", [app], stderr_to_stdout: true) end)
      Process.sleep(1500)
      :ok
    else
      {:error, "'#{app}' is not in the allowed application list"}
    end
  end

  def clipboard_get do
    if has?("wl-paste") do
      # `wl-paste` blocks on the compositor's data-offer handshake. A compositor
      # that never answers hangs it, and an empty string would be indistinguishable
      # from a genuinely empty clipboard.
      case BoundedCmd.run("wl-paste", ["--no-newline"],
             label: "wl-paste",
             target: "the Wayland compositor",
             stderr_to_stdout: false
           ) do
        {:ok, out, 0} ->
          {:ok, out}

        {:ok, output, code} ->
          {:error, "clipboard_get failed (exit #{code}): #{String.trim(output)}"}

        {:timeout, why} ->
          {:error, why}
      end
    else
      {:error, "clipboard_get unavailable (install wl-clipboard)"}
    end
  rescue
    e in ErlangError -> {:error, "clipboard_get failed: #{inspect(e)}"}
  end

  def clipboard_set(text) when is_binary(text), do: clipboard_write(text)
  def clipboard_clear, do: clipboard_write("")

  # ── Private ──────────────────────────────────────────────────────────

  defp region(opts), do: Map.get(opts, "region") || Map.get(opts, :region)

  defp pointer_click(x, y, code, label) do
    with :ok <- move_mouse(x, y) do
      run("ydotool", ["click", code], label)
    end
  end

  defp wtype_key_args(combo) do
    parts =
      combo |> String.downcase() |> String.split("+", trim: true) |> Enum.map(&String.trim/1)

    mods = Enum.drop(parts, -1)
    key = List.last(parts)
    mod_flags = Enum.flat_map(mods, fn m -> ["-M", Map.get(@wtype_mods, m, m)] end)

    release_flags =
      Enum.flat_map(Enum.reverse(mods), fn m -> ["-m", Map.get(@wtype_mods, m, m)] end)

    mod_flags ++ ["-k", Map.get(@wtype_keys, key, key)] ++ release_flags
  end

  defp clipboard_write(text) do
    if has?("wl-copy") do
      tmp = Path.join(System.tmp_dir!(), "osa_clip_#{System.unique_integer([:positive])}")

      try do
        File.write!(tmp, text)

        case BoundedCmd.run("sh", ["-c", "wl-copy < #{tmp}"],
               label: "wl-copy",
               target: "the Wayland compositor"
             ) do
          {:ok, _, 0} ->
            :ok

          {:ok, output, code} ->
            {:error, "clipboard write failed (exit #{code}): #{String.trim(output)}"}

          {:timeout, why} ->
            {:error, why}
        end
      after
        File.rm(tmp)
      end
    else
      {:error, "clipboard write unavailable (install wl-clipboard)"}
    end
  rescue
    e -> {:error, "clipboard write failed: #{inspect(e)}"}
  end

  defp has?(bin), do: System.find_executable(bin) != nil

  # The generic dispatch every Wayland input primitive goes through
  # (`ydotool`, `wtype`, `grim`). `ydotool` in particular blocks forever when
  # its daemon socket exists but nothing is reading it.
  defp run(cmd, args, label) do
    case BoundedCmd.run(cmd, args, label: label, target: "the Wayland compositor") do
      {:ok, _, 0} -> :ok
      {:ok, output, code} -> {:error, "#{label} failed (exit #{code}): #{String.trim(output)}"}
      {:timeout, why} -> {:error, why}
    end
  rescue
    e in ErlangError -> {:error, "#{label} failed (is #{cmd} installed?): #{inspect(e)}"}
  end
end
