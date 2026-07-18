defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.Windows do
  @moduledoc """
  Windows adapter — drives the desktop through PowerShell.

  Screenshots use System.Drawing; the pointer uses user32 `SetCursorPos` +
  `mouse_event`; the keyboard uses `System.Windows.Forms.SendKeys`; the
  clipboard uses `Set-Clipboard`/`Get-Clipboard`. Requires `powershell` (or
  `pwsh`) on PATH — standard on Windows 10/11.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  require Logger

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.AppAllowlist

  @sendkeys_keys %{
    "enter" => "{ENTER}",
    "return" => "{ENTER}",
    "tab" => "{TAB}",
    "esc" => "{ESC}",
    "escape" => "{ESC}",
    "backspace" => "{BACKSPACE}",
    "delete" => "{DELETE}",
    "space" => " ",
    "up" => "{UP}",
    "down" => "{DOWN}",
    "left" => "{LEFT}",
    "right" => "{RIGHT}",
    "home" => "{HOME}",
    "end" => "{END}",
    "pageup" => "{PGUP}",
    "pagedown" => "{PGDN}",
    "f1" => "{F1}",
    "f2" => "{F2}",
    "f3" => "{F3}",
    "f4" => "{F4}",
    "f5" => "{F5}",
    "f6" => "{F6}",
    "f7" => "{F7}",
    "f8" => "{F8}",
    "f9" => "{F9}",
    "f10" => "{F10}",
    "f11" => "{F11}",
    "f12" => "{F12}"
  }

  # ── Base behaviour callbacks ─────────────────────────────────────────

  @impl true
  def available? do
    match?({:win32, _}, :os.type()) and powershell() != nil
  end

  @impl true
  def screenshot(opts \\ %{}) do
    dir = Path.expand("~/.osa/screenshots")
    File.mkdir_p!(dir)
    path = Path.join(dir, "screenshot_#{System.system_time(:millisecond)}.png")
    win_path = String.replace(path, "/", "\\\\")

    bounds =
      case region(opts) do
        %{"x" => x, "y" => y, "width" => w, "height" => h} ->
          "New-Object Drawing.Rectangle(#{x}, #{y}, #{w}, #{h})"

        _ ->
          "[Windows.Forms.SystemInformation]::VirtualScreen"
      end

    script = """
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $b = #{bounds}
    $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
    $bmp.Save('#{win_path}', [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    """

    case ps(script, "Screenshot") do
      :ok -> {:ok, path}
      {:error, _} = err -> err
    end
  end

  @impl true
  def click(x, y), do: ps(mouse_script(x, y, "0x02", "0x04"), "Click")

  @impl true
  def double_click(x, y) do
    with :ok <- ps(mouse_script(x, y, "0x02", "0x04"), "Double click") do
      ps(mouse_script(x, y, "0x02", "0x04"), "Double click")
    end
  end

  @impl true
  def move_mouse(x, y), do: ps(move_script(x, y), "Move mouse")

  @impl true
  def drag(fx, fy, tx, ty) do
    script = """
    #{user32()}
    [Win.U]::SetCursorPos(#{fx}, #{fy})
    [Win.U]::mouse_event(0x02, 0, 0, 0, 0)
    [Win.U]::SetCursorPos(#{tx}, #{ty})
    [Win.U]::mouse_event(0x04, 0, 0, 0, 0)
    """

    ps(script, "Drag")
  end

  @impl true
  def type_text(text) do
    script = """
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait('#{sendkeys_escape(text)}')
    """

    ps(script, "Type")
  end

  @impl true
  def key_press(combo) do
    script = """
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait('#{sendkeys_combo(combo)}')
    """

    ps(script, "Key press")
  end

  @impl true
  def scroll(direction, amount) do
    steps = amount || 3

    delta =
      case direction do
        "up" -> 120 * steps
        "down" -> -120 * steps
        _ -> 0
      end

    if delta == 0 do
      {:error, "Windows scroll supports up/down only"}
    else
      script = """
      #{user32()}
      [Win.U]::mouse_event(0x0800, 0, 0, #{delta}, 0)
      """

      ps(script, "Scroll")
    end
  end

  @impl true
  def get_tree,
    do: {:error, "Windows accessibility tree (UIAutomation) not implemented; use screenshot"}

  # ── Extended callbacks ───────────────────────────────────────────────

  def right_click(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y),
    do: ps(mouse_script(x, y, "0x08", "0x10"), "Right click")

  def right_click(_), do: {:error, "right_click on Windows requires x,y coordinates"}

  def middle_click(x, y), do: ps(mouse_script(x, y, "0x20", "0x40"), "Middle click")

  def wait(seconds) do
    Process.sleep(trunc(max(0, min(seconds || 1, 30)) * 1000))
    :ok
  end

  def clipboard_get, do: ps_out("Get-Clipboard -Raw")

  def clipboard_set(text) when is_binary(text) do
    ps("Set-Clipboard -Value '#{String.replace(text, "'", "''")}'", "Clipboard set")
  end

  def clipboard_clear, do: ps("Set-Clipboard -Value ''", "Clipboard clear")

  def launch(app) when is_binary(app) do
    if AppAllowlist.allowed?(app) do
      case ps("Start-Process '#{String.replace(app, "'", "''")}'", "Launch") do
        :ok ->
          Process.sleep(1500)
          :ok

        err ->
          err
      end
    else
      {:error, "'#{app}' is not in the allowed application list"}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp region(opts), do: Map.get(opts, "region") || Map.get(opts, :region)

  defp user32 do
    ~s/Add-Type -MemberDefinition '[DllImport("user32.dll")]public static extern bool SetCursorPos(int x,int y);[DllImport("user32.dll")]public static extern void mouse_event(int f,int dx,int dy,int d,int e);' -Name U -Namespace Win | Out-Null/
  end

  defp mouse_script(x, y, down, up) do
    """
    #{user32()}
    [Win.U]::SetCursorPos(#{x}, #{y})
    [Win.U]::mouse_event(#{down}, 0, 0, 0, 0)
    [Win.U]::mouse_event(#{up}, 0, 0, 0, 0)
    """
  end

  defp move_script(x, y) do
    """
    #{user32()}
    [Win.U]::SetCursorPos(#{x}, #{y})
    """
  end

  defp sendkeys_escape(text) do
    text
    |> String.replace("'", "''")
    |> String.graphemes()
    |> Enum.map_join(fn
      c when c in ["{", "}", "(", ")", "+", "^", "%", "~", "[", "]"] -> "{#{c}}"
      c -> c
    end)
  end

  defp sendkeys_combo(combo) do
    parts = combo |> String.downcase() |> String.split("+", trim: true)
    mods = Enum.drop(parts, -1)
    key = List.last(parts)
    prefix = Enum.map_join(mods, &sendkeys_mod/1)
    prefix <> sendkeys_key(key)
  end

  defp sendkeys_mod(m) when m in ["ctrl", "control"], do: "^"
  defp sendkeys_mod(m) when m in ["alt", "option"], do: "%"
  defp sendkeys_mod("shift"), do: "+"
  defp sendkeys_mod(_), do: ""

  defp sendkeys_key(key), do: Map.get(@sendkeys_keys, key, key)

  defp powershell, do: System.find_executable("pwsh") || System.find_executable("powershell")

  defp ps(script, label) do
    case powershell() do
      nil ->
        {:error, "#{label} requires PowerShell"}

      exe ->
        case System.cmd(exe, ["-NoProfile", "-NonInteractive", "-Command", script],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, code} -> {:error, "#{label} failed (exit #{code}): #{String.trim(out)}"}
        end
    end
  rescue
    e in ErlangError -> {:error, "#{label} failed: #{inspect(e)}"}
  end

  defp ps_out(script) do
    case powershell() do
      nil ->
        {:error, "PowerShell not found"}

      exe ->
        case System.cmd(exe, ["-NoProfile", "-NonInteractive", "-Command", script],
               stderr_to_stdout: false
             ) do
          {out, 0} -> {:ok, out}
          {out, code} -> {:error, "PowerShell read failed (exit #{code}): #{String.trim(out)}"}
        end
    end
  rescue
    e in ErlangError -> {:error, "PowerShell read failed: #{inspect(e)}"}
  end
end
