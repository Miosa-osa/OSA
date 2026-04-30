defmodule OptimalSystemAgent.OpenComputers.Session.Fingerprint do
  @moduledoc """
  Ed25519 identity key for this OSA host.

  First boot: generates a fresh private key, writes it to
  `fingerprint_path` with `0600` permissions, creates any missing
  parent directories. Subsequent boots: reads the existing file.

  The control plane pins these bytes on first successful hello —
  every reconnect thereafter must present the same bytes.
  """

  require Logger

  @spec load_or_generate(String.t()) :: binary()
  def load_or_generate(path) do
    full = Path.expand(path)

    case File.read(full) do
      {:ok, bin} ->
        bin

      {:error, :enoent} ->
        generate(full)

      {:error, reason} ->
        Logger.error(
          "[OpenComputers.Session.Fingerprint] cannot read #{full}: #{inspect(reason)}"
        )

        :crypto.strong_rand_bytes(32)
    end
  end

  defp generate(full) do
    Logger.info("[OpenComputers.Session.Fingerprint] generating ed25519 fingerprint at #{full}")
    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, priv, [:binary])
    File.chmod!(full, 0o600)
    priv
  end
end
