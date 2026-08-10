defmodule OptimalSystemAgent.Usage.RateLimits do
  @moduledoc """
  The last quota window a provider *reported to us*, per provider.

  ## Why this is a cache and not a lookup

  None of the subscription providers OSA supports exposes a "how much of my
  plan is left" endpoint that can be called for free. What OpenAI's Codex
  backend does expose is a set of `x-codex-*` response headers attached to
  inference responses it was going to return anyway. So the only way to learn
  the remaining quota without spending anything is to *remember what the last
  real request already told us*.

  That makes every value in here a measurement with an age. `/usage` renders
  the age next to the number for exactly that reason: a 40% figure observed
  four hours ago is not a claim about right now, and presenting it as one
  would be the kind of confidently-wrong number this codebase has been burned
  on before. When nothing has been observed the answer is "not reported yet",
  never a zero.

  ## Read-only contract

  `get/1` and `all/0` perform no network I/O and cannot spend a metered
  request — they are safe to call from a status screen, in a loop.

  ## Surviving a cold CLI

  `osa usage` runs under `mix run --no-start`, so this GenServer is not alive
  there. Observations are therefore written through to a small JSON file
  (throttled, never on the hot path's critical section) and reads fall back to
  it. A cold CLI sees the same numbers the REPL does, with the same age.
  """

  use GenServer

  require Logger

  @name __MODULE__
  @filename "provider_quota.json"

  # Disk is a convenience for the cold-CLI path, not the source of truth.
  # Writing on every response would put a file write in the middle of every
  # inference turn for a value that changes by fractions of a percent.
  @write_throttle_ms 30_000

  @type observation :: %{
          required(:observed_at) => integer(),
          optional(:used_percent) => number() | nil,
          optional(:window_minutes) => number() | nil,
          optional(:resets_at) => String.t() | nil,
          optional(:limit_name) => String.t() | nil
        }

  # ── Client ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Record a quota window a provider just reported.

  Fire-and-forget: a `cast` that is a no-op when the process is not running,
  because this is called from the response path of every inference request and
  must never be able to fail or block one.
  """
  @spec record(String.t() | atom(), map() | nil) :: :ok
  def record(_provider_id, nil), do: :ok
  def record(_provider_id, info) when info == %{}, do: :ok

  def record(provider_id, info) when is_map(info) do
    GenServer.cast(@name, {:record, to_string(provider_id), info})
  catch
    # Not started (cold CLI, `--no-start`, or a test without the tree). The
    # observation is lost, which is strictly better than crashing a turn.
    :exit, _ -> :ok
  end

  def record(_provider_id, _info), do: :ok

  @doc """
  The last observation for a provider, or `nil` when nothing has been seen.

  `nil` means "not reported yet" and must be rendered as such. It does not
  mean zero.
  """
  @spec get(String.t() | atom()) :: observation() | nil
  def get(provider_id), do: Map.get(all(), to_string(provider_id))

  @doc "Every observation, keyed by provider id. Pure read; never dials out."
  @spec all() :: %{optional(String.t()) => observation()}
  def all do
    GenServer.call(@name, :all, 1_000)
  catch
    :exit, _ -> read_file()
  end

  @doc "Forget everything. Test support."
  @spec reset() :: :ok
  def reset do
    GenServer.call(@name, :reset, 1_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Path of the write-through cache."
  @spec path() :: String.t()
  def path do
    dir = System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")
    Path.join(dir, @filename)
  rescue
    _ -> Path.join(System.tmp_dir!(), @filename)
  end

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{entries: read_file(), last_write_ms: 0}}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state.entries, state}

  def handle_call(:reset, _from, state) do
    _ = File.rm(path())
    {:reply, :ok, %{state | entries: %{}, last_write_ms: 0}}
  end

  @impl true
  def handle_cast({:record, provider_id, info}, state) do
    entry =
      info
      |> Map.take([:used_percent, :window_minutes, :resets_at, :limit_name])
      |> Map.put(:observed_at, System.system_time(:second))

    entries = Map.put(state.entries, provider_id, entry)
    now = System.monotonic_time(:millisecond)

    if now - state.last_write_ms >= @write_throttle_ms do
      write_file(entries)
      {:noreply, %{state | entries: entries, last_write_ms: now}}
    else
      {:noreply, %{state | entries: entries}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    write_file(state.entries)
    :ok
  end

  # ── Disk ────────────────────────────────────────────────────────────────

  defp read_file do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"providers" => providers}} when is_map(providers) <- Jason.decode(body) do
      Map.new(providers, fn {id, fields} -> {id, atomize(fields)} end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # Only the keys this module writes are converted, so a corrupted or
  # hand-edited file cannot grow the atom table.
  @known_keys ~w(observed_at used_percent window_minutes resets_at limit_name)

  defp atomize(fields) when is_map(fields) do
    for {k, v} <- fields, k in @known_keys, into: %{}, do: {String.to_existing_atom(k), v}
  end

  defp atomize(_), do: %{}

  defp write_file(entries) do
    path = path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"version" => 1, "providers" => entries}))
    :ok
  rescue
    e ->
      Logger.debug("Usage.RateLimits: could not persist quota cache: #{inspect(e)}")
      :ok
  end
end
