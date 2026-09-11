defmodule OptimalSystemAgent.Test.ColdAdapter do
  @moduledoc """
  A `ComputerUse.Adapter` that exists only so a test can UNLOAD it.

  ## Why this has to live in `test/support`

  It needs a real `.beam` on the code path. `test/support` is in
  `elixirc_paths(:test)`, so Mix compiles it to disk; a module defined inside a
  `.exs` test file is compiled in memory and has no `.beam` to reload. A test
  that purges the latter cannot tell "unloaded but loadable" from "deleted and
  gone", and so cannot exercise the defect it means to cover — the first version
  of this fixture did exactly that and failed against the fix.

  ## What it is for

  `function_exported?/3` answers `false` for a module that has not been loaded,
  and it does not load one. `Adapter.adapter_for/1` picks an adapter by module
  ATOM and never calls it, and `Server.init/1` only stores it, so on a fresh
  release VM — where modules load lazily — `state.adapter` is genuinely unloaded
  when the first `computer_use` action dispatches. Against that state, nine
  dispatch clauses in `ComputerUse.Server` reported a supported action as
  "is not supported by ..." for an adapter that implements it.

  Implementing every required callback keeps this from emitting a
  "function required by behaviour is not implemented" warning while staying
  deliberately trivial: the test asserts on whether the SERVER can see the
  function, not on what the function does.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  @impl true
  def available?, do: true

  @impl true
  def screenshot(_opts), do: {:ok, "/tmp/cold_adapter_screenshot.png"}

  @impl true
  def click(_x, _y), do: :ok

  @impl true
  def double_click(_x, _y), do: :ok

  @impl true
  def type_text(_text), do: :ok

  @impl true
  def key_press(_combo), do: :ok

  @impl true
  def scroll(_direction, _amount), do: :ok

  @impl true
  def move_mouse(_x, _y), do: :ok

  @impl true
  def drag(_from_x, _from_y, _to_x, _to_y), do: :ok

  @impl true
  def get_tree, do: {:ok, []}

  # The two actions reported broken in the wild. Both are defined here, and the
  # test asserts the server reaches them while this module is unloaded.
  def list_windows, do: {:ok, [%{"app" => "Finder", "title" => "Desktop"}]}
  def snapshot(_params), do: {:ok, [%{role: "window", name: "Desktop"}]}

  # Deliberately NOT defined: `cursor/0`. The test that asserts a genuine
  # absence still reports one honestly needs a function that is really missing.
end
