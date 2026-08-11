defmodule OptimalSystemAgent.System.Updater do
  @moduledoc """
  OTA update checks with TUF-style signature verification.

  Checks for updates on a configurable schedule. Does NOT auto-apply — the user
  must explicitly confirm updates.

  ## Trust model — read before touching `stage_update/2`

  Update metadata is fetched over the network from `:update_url`. Whoever can
  answer that URL — the host, a CDN edge, a TLS-terminating proxy, anyone who
  can redirect it — controls every byte of it. Until this module was hardened,
  the fetched document was parsed and believed: `do_check/1` read
  `signed.version` straight out of it and emitted `:update_available`, and no
  code path anywhere examined the `signatures` key. It was TUF-shaped without
  being TUF. That was latent only because staging was a stub; the moment
  staging installs what the metadata names, answering the update URL is remote
  code execution.

  So verification is now a precondition, structured so it cannot be skipped by
  accident:

    * `verify_metadata/3` requires a `signatures` array meeting a threshold of
      Ed25519 signatures from **pinned root keys held in local config**, over
      the canonical serialization of the `signed` object. Keys that arrive in
      the fetched document itself are never trusted — that is the circularity
      TUF exists to break.
    * **No pinned keys ⇒ no update.** `do_check/1` returns
      `{:error, :no_pinned_root_keys}` and emits nothing. Unverified metadata
      cannot produce an `:update_available` event, so nothing downstream can
      act on it.
    * **Rollback protection.** Metadata `version` must be monotonic per role
      (an attacker replaying an old, validly-signed document cannot pin you to
      a vulnerable release), and the offered release version must be strictly
      newer than the running one.
    * **Freshness.** `signed.expires` must be in the future.
    * **Installation gate.** `ensure_installable/1` is the single entry point
      staging may use, and it rejects anything not carrying a
      `verified: true` stamp minted by `verify_metadata/3` in this process.

  ### If you are here to implement real staging

  Call `ensure_installable/1` first and honor its error. The test
  `test/system/updater_test.exs` asserts that staging refuses unverified
  metadata; it exists specifically so that wiring installation to an unverified
  document turns the suite red instead of shipping.

  Note that signature verification covers the **metadata**. A real installer
  must additionally verify the downloaded artifact against the hash/length
  recorded in the verified `targets` document before executing it.

  ## Configuration

      config :optimal_system_agent,
        update_enabled: false,
        update_url: "https://updates.example.com/tuf",
        # Pinned Ed25519 root public keys, hex-encoded. NO DEFAULT — absent
        # means updates are refused, never means "trust whatever arrives".
        update_root_keys: [%{"keyid" => "ab12…", "public" => "9f3c…"}],
        update_root_threshold: 1
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @default_interval 86_400_000
  @default_threshold 1

  # Roles fetched and verified on every check.
  @roles ~w(root timestamp targets)

  defstruct update_url: nil,
            check_interval: @default_interval,
            last_check: nil,
            available_update: nil,
            tuf_root: nil,
            # Highest metadata version seen per role — rollback protection.
            seen_versions: %{},
            enabled: false

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Manually trigger an update check."
  @spec check_now() :: {:ok, map() | nil} | {:error, String.t()}
  def check_now do
    GenServer.call(__MODULE__, :check_now, 30_000)
  end

  @doc "Get the currently available update, if any."
  @spec available_update() :: map() | nil
  def available_update do
    GenServer.call(__MODULE__, :available_update)
  end

  @doc "Apply a staged update (downloads, verifies hash, stages for restart)."
  @spec apply_update(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def apply_update(version) do
    GenServer.call(__MODULE__, {:apply_update, version}, 60_000)
  end

  @impl true
  def init(_opts) do
    enabled = Application.get_env(:optimal_system_agent, :update_enabled, false)
    url = Application.get_env(:optimal_system_agent, :update_url)
    interval = Application.get_env(:optimal_system_agent, :update_interval, @default_interval)

    state = %__MODULE__{
      update_url: url,
      check_interval: interval,
      enabled: enabled
    }

    if enabled and url do
      Logger.info("[Updater] Enabled — checking #{url} every #{div(interval, 3_600_000)}h")
      schedule_check(interval)
    else
      Logger.info("[Updater] Disabled or no update URL configured")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    case do_check(state) do
      {:ok, update_info, new_state} ->
        {:reply, {:ok, update_info}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:no_update, new_state} ->
        {:reply, {:ok, nil}, new_state}
    end
  end

  @impl true
  def handle_call(:available_update, _from, state) do
    {:reply, state.available_update, state}
  end

  @impl true
  def handle_call({:apply_update, version}, _from, state) do
    case state.available_update do
      %{version: ^version} = update ->
        case stage_update(state, update) do
          {:ok, staged_path} ->
            Logger.info("[Updater] Update #{version} staged at #{staged_path}")

            Bus.emit(:system_event, %{
              event: :update_staged,
              version: version,
              path: staged_path
            })

            {:reply, {:ok, staged_path}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      nil ->
        {:reply, {:error, "No update available"}, state}

      %{version: other} ->
        {:reply, {:error, "Available version is #{other}, not #{version}"}, state}
    end
  end

  @impl true
  def handle_info(:check_update, state) do
    new_state =
      case do_check(state) do
        {:ok, _update_info, new_state} ->
          new_state

        {:error, reason} ->
          Logger.warning("[Updater] Check failed: #{reason}")
          state

        {:no_update, new_state} ->
          new_state
      end

    schedule_check(state.check_interval)
    {:noreply, new_state}
  end

  defp do_check(%{update_url: nil}), do: {:error, "No update URL configured"}

  defp do_check(%{update_url: url} = state) do
    current_version = current_version()
    Logger.debug("[Updater] Checking for updates at #{url}")

    with {:ok, keys, threshold} <- pinned_root_keys(),
         {:ok, docs, seen} <- fetch_and_verify_all(url, keys, threshold, state.seen_versions) do
      %{"root" => root, "timestamp" => timestamp, "targets" => targets} = docs

      latest_version =
        get_in(targets, ["signed", "version"]) ||
          get_in(targets, ["signed", "targets", "latest", "custom", "version"])

      state = %{state | seen_versions: seen}

      if latest_version && version_newer?(latest_version, current_version) do
        update_info = %{
          version: latest_version,
          current_version: current_version,
          url: url,
          discovered_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          # Stamped ONLY here, only after every role verified against pinned
          # keys. `ensure_installable/1` refuses anything without it.
          verified: true,
          verified_at: System.system_time(:second),
          metadata: %{
            root_version: get_in(root, ["signed", "version"]),
            timestamp_version: get_in(timestamp, ["signed", "version"]),
            targets_version: get_in(targets, ["signed", "version"])
          }
        }

        Logger.info("[Updater] Verified update available: #{current_version} -> #{latest_version}")

        Bus.emit(:system_event, %{
          event: :update_available,
          version: latest_version,
          current: current_version,
          verified: true
        })

        new_state = %{
          state
          | available_update: update_info,
            last_check: DateTime.utc_now(),
            tuf_root: root
        }

        {:ok, update_info, new_state}
      else
        {:no_update, %{state | last_check: DateTime.utc_now()}}
      end
    else
      {:error, reason} ->
        # An unverifiable document is a security event, not a hiccup. Say so
        # loudly and emit NOTHING that downstream code could act on.
        Logger.error("[Updater] Refusing update metadata from #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[Updater] Check failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Fetch and verify every role, threading rollback state through.

  Returns `{:ok, %{role => document}, seen_versions}` only when ALL roles
  verify. Public for testing.
  """
  @spec fetch_and_verify_all(String.t(), list(), pos_integer(), map()) ::
          {:ok, map(), map()} | {:error, term()}
  def fetch_and_verify_all(url, keys, threshold, seen_versions) do
    Enum.reduce_while(@roles, {:ok, %{}, seen_versions}, fn role, {:ok, acc, seen} ->
      with {:ok, doc} <- fetch_tuf_metadata(url, "#{role}.json"),
           :ok <- verify_metadata(doc, keys, threshold),
           {:ok, seen} <- check_rollback(role, doc, seen) do
        {:cont, {:ok, Map.put(acc, role, doc), seen}}
      else
        {:error, reason} -> {:halt, {:error, {role, reason}}}
        other -> {:halt, {:error, {role, other}}}
      end
    end)
  end

  @doc """
  The pinned root keys from local config.

  `{:error, :no_pinned_root_keys}` when none are configured — which is the
  default. There is deliberately no fallback to keys embedded in the fetched
  document: trusting the document to say who may sign the document is the exact
  circularity signature verification exists to break.
  """
  @spec pinned_root_keys() :: {:ok, [{binary(), binary()}], pos_integer()} | {:error, atom()}
  def pinned_root_keys do
    raw = Application.get_env(:optimal_system_agent, :update_root_keys, [])
    threshold = Application.get_env(:optimal_system_agent, :update_root_threshold, @default_threshold)

    keys =
      raw
      |> List.wrap()
      |> Enum.map(&parse_key/1)
      |> Enum.reject(&is_nil/1)

    cond do
      keys == [] -> {:error, :no_pinned_root_keys}
      not (is_integer(threshold) and threshold >= 1) -> {:error, :invalid_threshold}
      length(keys) < threshold -> {:error, :threshold_exceeds_pinned_keys}
      true -> {:ok, keys, threshold}
    end
  end

  # Accepts %{"keyid" => hex, "public" => hex} or a bare hex public key
  # (keyid then derived as the SHA-256 of the raw key, TUF-style).
  defp parse_key(%{} = m) do
    pub = m["public"] || m[:public] || m["keyval"]["public"]

    with true <- is_binary(pub),
         {:ok, raw} <- decode_hex(pub) do
      {m["keyid"] || m[:keyid] || derive_keyid(raw), raw}
    else
      _ -> nil
    end
  end

  defp parse_key(hex) when is_binary(hex) do
    case decode_hex(hex) do
      {:ok, raw} -> {derive_keyid(raw), raw}
      _ -> nil
    end
  end

  defp parse_key(_), do: nil

  defp decode_hex(hex) do
    case Base.decode16(String.downcase(hex), case: :lower) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> :error
    end
  end

  defp derive_keyid(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  @doc """
  Verify a TUF-style document: `%{"signed" => …, "signatures" => [%{"keyid", "sig"}]}`.

  Requires at least `threshold` valid Ed25519 signatures from DISTINCT pinned
  keyids over `canonical_json(signed)`, and requires `signed.expires` (when
  present) to be in the future.

  Returns `:ok` or `{:error, reason}`. Public for testing.
  """
  @spec verify_metadata(term(), [{binary(), binary()}], pos_integer()) :: :ok | {:error, term()}
  def verify_metadata(doc, keys, threshold) when is_map(doc) do
    signed = Map.get(doc, "signed")
    sigs = Map.get(doc, "signatures")

    cond do
      not is_map(signed) ->
        {:error, :missing_signed}

      not is_list(sigs) or sigs == [] ->
        {:error, :missing_signatures}

      true ->
        payload = canonical_json(signed)
        key_map = Map.new(keys)

        valid_keyids =
          sigs
          |> Enum.filter(&valid_signature?(&1, key_map, payload))
          |> Enum.map(&Map.get(&1, "keyid"))
          |> Enum.uniq()

        cond do
          length(valid_keyids) < threshold ->
            {:error, {:signature_threshold_not_met, length(valid_keyids), threshold}}

          expired?(signed) ->
            {:error, :metadata_expired}

          true ->
            :ok
        end
    end
  rescue
    e -> {:error, {:verification_error, Exception.message(e)}}
  end

  def verify_metadata(_doc, _keys, _threshold), do: {:error, :not_a_document}

  defp valid_signature?(%{"keyid" => keyid, "sig" => sig_hex}, key_map, payload)
       when is_binary(keyid) and is_binary(sig_hex) do
    case Map.fetch(key_map, keyid) do
      {:ok, pub} ->
        case Base.decode16(String.downcase(sig_hex), case: :lower) do
          {:ok, sig} -> :crypto.verify(:eddsa, :none, payload, sig, [pub, :ed25519])
          _ -> false
        end

      :error ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_signature?(_, _, _), do: false

  defp expired?(%{"expires" => expires}) when is_binary(expires) do
    case DateTime.from_iso8601(expires) do
      {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  defp expired?(_), do: false

  @doc """
  Rollback protection: metadata `version` must never go backwards for a role.

  A replayed but validly-signed old document would otherwise re-offer a release
  the operator already moved past — the standard way to pin a target back onto
  a known-vulnerable build. Public for testing.
  """
  @spec check_rollback(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def check_rollback(role, doc, seen) do
    version = get_in(doc, ["signed", "version"])
    previous = Map.get(seen, role)

    cond do
      not is_integer(version) -> {:error, :missing_metadata_version}
      is_integer(previous) and version < previous -> {:error, {:rollback_detected, version, previous}}
      true -> {:ok, Map.put(seen, role, version)}
    end
  end

  @doc """
  Canonical serialization used as the signed payload.

  Object keys sorted, no insignificant whitespace — so signer and verifier
  agree on bytes regardless of map ordering.
  """
  @spec canonical_json(term()) :: iodata()
  def canonical_json(term), do: IO.iodata_to_binary(do_canonical(term))

  defp do_canonical(m) when is_map(m) do
    inner =
      m
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", do_canonical(v)] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp do_canonical(l) when is_list(l),
    do: ["[", l |> Enum.map(&do_canonical/1) |> Enum.intersperse(","), "]"]

  defp do_canonical(v), do: Jason.encode!(v)

  defp fetch_tuf_metadata(base_url, filename) do
    url = "#{String.trim_trailing(base_url, "/")}/#{filename}"

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} fetching #{filename}"}

      {:error, reason} ->
        {:error, "Failed to fetch #{filename}: #{inspect(reason)}"}
    end
  end

  @doc """
  THE installation gate. Any code that downloads, stages, unpacks, or executes
  anything named by update metadata MUST call this first and honor its error.

  Returns `:ok` only for an update record stamped `verified: true` by
  `do_check/1` after full signature + rollback + freshness verification in this
  process. A record assembled from a raw fetched document — or hand-built, or
  read back from disk — does not carry the stamp and is refused.
  """
  @spec ensure_installable(term()) :: :ok | {:error, term()}
  def ensure_installable(%{verified: true, version: version}) when is_binary(version), do: :ok

  def ensure_installable(%{} = update) do
    {:error,
     "REFUSING to install update #{inspect(Map.get(update, :version))}: its metadata was not " <>
       "verified against pinned root keys. Update metadata is attacker-controlled by anyone " <>
       "who can answer the update URL; installing from it unverified is remote code execution. " <>
       "Configure :update_root_keys and route the metadata through verify_metadata/3."}
  end

  def ensure_installable(_), do: {:error, "REFUSING to install: no update record"}

  defp stage_update(_state, update) do
    with :ok <- ensure_installable(update) do
      %{url: url, version: version} = update
      home = System.user_home!()
      staging_dir = Path.join([home, ".osa", "updates"])
      File.mkdir_p!(staging_dir)
      staged_path = Path.join(staging_dir, "osa-#{version}.staged")

      # STILL A STUB — it writes a marker, it does not download or install.
      #
      # Whoever replaces this with a real download must ALSO verify the
      # artifact bytes against the hash/length in the verified targets
      # document before anything executes. `ensure_installable/1` above
      # certifies the metadata, not the payload.
      File.write!(
        staged_path,
        Jason.encode!(%{
          version: version,
          staged_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          source: url,
          metadata_verified: true
        })
      )

      {:ok, staged_path}
    end
  rescue
    e -> {:error, "Staging failed: #{Exception.message(e)}"}
  end

  defp current_version do
    Application.spec(:optimal_system_agent, :vsn) |> to_string()
  rescue
    _ -> "0.0.0"
  end

  defp version_newer?(new_str, current_str) do
    with {:ok, new_ver} <- Version.parse(normalize_version(new_str)),
         {:ok, cur_ver} <- Version.parse(normalize_version(current_str)) do
      Version.compare(new_ver, cur_ver) == :gt
    else
      _ -> false
    end
  end

  defp normalize_version(v) do
    v = String.trim_leading(v, "v")
    parts = String.split(v, ".")

    case length(parts) do
      1 -> v <> ".0.0"
      2 -> v <> ".0"
      _ -> v
    end
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_update, interval)
  end
end
