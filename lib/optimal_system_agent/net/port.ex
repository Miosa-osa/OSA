defmodule OptimalSystemAgent.Net.Port do
  @moduledoc """
  Single source of truth for HTTP port resolution, bind-availability, and
  holder classification.

  Shared by three call sites so they can never disagree about whether the
  configured HTTP port is free, held by another OSA instance, or held by a
  foreign process:

    * boot preflight  — `OptimalSystemAgent.Application.start/2` (halts cleanly
      instead of letting Bandit fail to bind → `rest_for_one` restart loop →
      cryptic app-wide crash)
    * `osa doctor`    — `OptimalSystemAgent.CLI.Doctor` (`API` check)
    * onboarding      — `OptimalSystemAgent.CLI.Setup` + the setup wizard

  Resolution mirrors Bandit's bind exactly: loopback (`127.0.0.1`) on the
  configured port. Port 0 is the ephemeral "pick any free port" port and is
  therefore always reported available.
  """

  @app :optimal_system_agent
  @default_port 9089

  # Distinctive markers in OSA's `GET /health` JSON body, used to tell an OSA
  # instance apart from an unrelated process that merely holds the port. Both
  # must be present to classify as `:osa`.
  @osa_health_markers ["\"status\"", "\"uptime_seconds\""]

  @typedoc "Who currently holds the configured HTTP port."
  @type holder :: :free | :osa | :foreign

  @doc """
  Resolve the configured HTTP port the SAME way boot, doctor, and onboarding
  must all see it: `OSA_HTTP_PORT` env wins, else the app-env `:http_port`,
  else #{@default_port}.

  A non-integer `OSA_HTTP_PORT` (e.g. a typo) falls back to the app-env /
  default rather than raising — resilience over a cryptic crash.
  """
  @spec configured_http_port() :: non_neg_integer()
  def configured_http_port do
    case System.get_env("OSA_HTTP_PORT") do
      nil ->
        Application.get_env(@app, :http_port, @default_port)

      str ->
        case Integer.parse(str) do
          {port, _rest} when port >= 0 -> port
          _ -> Application.get_env(@app, :http_port, @default_port)
        end
    end
  end

  @doc """
  True if `port` can be bound (listened) on loopback right now — i.e. Bandit
  would succeed rather than failing with `:eaddrinuse`.

  Port 0 always binds (ephemeral), so returns true.
  """
  @spec available?(non_neg_integer()) :: boolean()
  def available?(port) when is_integer(port) and port >= 0 do
    # Mirror Bandit/ThousandIsland's loopback bind. No `reuseaddr` so that an
    # already-listening socket reliably surfaces `:eaddrinuse`.
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Classify who holds `port`:

    * `:free`    — bindable now (nothing is listening)
    * `:osa`     — occupied AND `GET /health` answers as OSA
    * `:foreign` — occupied by some other process

  Never raises; any probe failure degrades to `:foreign`.
  """
  @spec holder_kind(non_neg_integer()) :: holder()
  def holder_kind(port) when is_integer(port) and port >= 0 do
    if available?(port) do
      :free
    else
      if osa_health?(port), do: :osa, else: :foreign
    end
  end

  # Raw HTTP/1.1 GET /health over gen_tcp — deliberately dependency-free so it
  # works during boot preflight before :req/:inets are guaranteed started.
  defp osa_health?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.send(
          socket,
          "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        )

        body = recv_all(socket, [])
        :gen_tcp.close(socket)
        Enum.all?(@osa_health_markers, &String.contains?(body, &1))

      {:error, _reason} ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, [acc, chunk])
      {:error, _} -> IO.iodata_to_binary(acc)
    end
  end
end
