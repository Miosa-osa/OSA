defmodule OptimalSystemAgent.Remote.PtyBridge do
  @moduledoc """
  Bridges the local terminal to a remote PTY session brokered through the
  control plane.

  It forwards local stdin bytes as `{:pty_input, ...}` frames, renders inbound
  `{:pty_output, ...}` frames to a local sink, forwards terminal resizes as
  `{:pty_resize, ...}`, and terminates cleanly on `{:pty_close, ...}`.

  ## Injectable transport (testable offline)

  The bridge never talks to a socket directly. It is constructed with a
  `:send_fn` (arity-1 function that receives a frame to transmit) and an
  `:out_fn` (arity-1 function that receives output bytes to render). In
  production these wrap `Remote.Client.send_frame/2` and `IO.binwrite/2`; in
  tests they capture into the test process, so the whole bridge exercises with
  no live server.

  ## Driving the bridge

  `step/2` is a pure-ish reducer over a single event:

    * `{:stdin, bytes}` — user typed bytes -> emits a `pty_input` frame
    * `{:resize, cols, rows}` — SIGWINCH -> emits a `pty_resize` frame
    * `{:remote_frame, frame}` — an inbound frame from the broker

  It returns `{:cont, state}` to keep going or `{:halt, exit_code, state}` when
  the remote shell has closed. `loop/1` is the thin blocking wrapper that reads
  those events from the mailbox and applies `step/2`; `Remote.CLI` wires real
  stdin and `Client.stream_to/2` into it.
  """

  @enforce_keys [:session_id, :send_fn, :out_fn]
  defstruct [:session_id, :send_fn, :out_fn, cols: 80, rows: 24, opened?: false]

  @type t :: %__MODULE__{}

  alias OptimalSystemAgent.Remote.Frames

  @doc """
  Build a bridge. Options:
    * `:send_fn` (required) — arity-1, called with each frame to transmit
    * `:out_fn` — arity-1, called with output bytes (default `IO.binwrite/1`)
    * `:cols`, `:rows` — initial geometry
  """
  @spec new(String.t(), keyword()) :: t()
  def new(session_id, opts) when is_binary(session_id) do
    %__MODULE__{
      session_id: session_id,
      send_fn: Keyword.fetch!(opts, :send_fn),
      out_fn: Keyword.get(opts, :out_fn, &default_out/1),
      cols: Keyword.get(opts, :cols, 80),
      rows: Keyword.get(opts, :rows, 24)
    }
  end

  @doc "Emit the opening `pty_open_request` frame for this session."
  @spec open(t(), String.t() | nil, keyword()) :: t()
  def open(%__MODULE__{} = state, shell \\ nil, opts \\ []) do
    frame = Frames.pty_open(state.session_id, shell, state.cols, state.rows, opts)
    emit(state, frame)
    state
  end

  @doc "Forward local stdin bytes as a `pty_input` frame."
  @spec input(t(), binary()) :: t()
  def input(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    emit(state, Frames.pty_input(state.session_id, bytes))
    state
  end

  @doc "Forward a terminal resize as a `pty_resize` frame."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%__MODULE__{} = state, cols, rows) do
    emit(state, Frames.pty_resize(state.session_id, cols, rows))
    %{state | cols: cols, rows: rows}
  end

  @doc "Emit a `pty_close` frame (client-initiated teardown)."
  @spec close(t(), integer()) :: t()
  def close(%__MODULE__{} = state, exit_code \\ 0) do
    emit(state, Frames.pty_close(state.session_id, exit_code))
    state
  end

  @doc """
  Apply one event. Returns `{:cont, state}` or `{:halt, exit_code, state}`.
  """
  @spec step(t(), term()) :: {:cont, t()} | {:halt, integer(), t()}
  def step(%__MODULE__{} = state, {:stdin, bytes}) when is_binary(bytes) do
    {:cont, input(state, bytes)}
  end

  def step(%__MODULE__{} = state, {:resize, cols, rows}) do
    {:cont, resize(state, cols, rows)}
  end

  def step(%__MODULE__{} = state, {:remote_frame, frame}) do
    handle_frame(state, frame)
  end

  def step(%__MODULE__{} = state, :eof) do
    {:halt, 0, close(state)}
  end

  def step(%__MODULE__{} = state, _other), do: {:cont, state}

  @doc """
  Blocking event loop. Reads `{:stdin, _}`, `{:resize, _, _}`, and
  `{:remote_frame, _}` messages and applies `step/2` until the session closes.
  Returns the shell's exit code.
  """
  @spec loop(t()) :: integer()
  def loop(%__MODULE__{} = state) do
    receive do
      msg ->
        case step(state, msg) do
          {:cont, state} -> loop(state)
          {:halt, exit_code, _state} -> exit_code
        end
    end
  end

  # ── Inbound frame handling ───────────────────────────────────────────────────

  defp handle_frame(state, {:pty_opened, %{session_id: sid}}) do
    if sid == state.session_id, do: {:cont, %{state | opened?: true}}, else: {:cont, state}
  end

  defp handle_frame(state, {:pty_output, %{session_id: sid, data: data}}) do
    if sid == state.session_id, do: state.out_fn.(data)
    {:cont, state}
  end

  defp handle_frame(state, {:pty_close, %{session_id: sid} = payload}) do
    if sid == state.session_id do
      {:halt, Map.get(payload, :exit_code, 0), state}
    else
      {:cont, state}
    end
  end

  defp handle_frame(state, {:pty_error, %{session_id: sid, reason: reason}}) do
    if sid == state.session_id do
      state.out_fn.("\r\n[pty error: #{inspect(reason)}]\r\n")
      {:halt, 1, state}
    else
      {:cont, state}
    end
  end

  defp handle_frame(state, {:__closed__, _code}) do
    state.out_fn.("\r\n[remote broker closed the connection]\r\n")
    {:halt, 1, state}
  end

  defp handle_frame(state, _other), do: {:cont, state}

  # ── Private ──────────────────────────────────────────────────────────────────

  defp emit(%__MODULE__{send_fn: send_fn}, frame), do: send_fn.(frame)

  defp default_out(data), do: IO.binwrite(data)
end
