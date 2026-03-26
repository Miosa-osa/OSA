defmodule OptimalSystemAgent.Receipt.Replayer do
  @moduledoc """
  Replay-verifies signed receipts stored on disk.

  Reads `*.json` files from the signed receipts directory, extracts
  `kernel_response.attestation` + `kernel_response.signature`, and
  verifies each against the kernel's Ed25519 public key.
  """

  require Logger

  @signed_dir Path.join(System.user_home!(), ".daemon/receipts/signed")

  @type replay_result :: %{
          total: non_neg_integer(),
          verified: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          failures: [String.t()]
        }

  @doc """
  Replay-verify all signed receipts in `dir` using `pubkey_hex`.
  """
  @spec replay_all(String.t(), String.t()) :: replay_result()
  def replay_all(pubkey_hex, dir \\ @signed_dir) do
    initial = %{total: 0, verified: 0, failed: 0, skipped: 0, failures: []}

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce(initial, fn filename, acc ->
          path = Path.join(dir, filename)
          acc = %{acc | total: acc.total + 1}

          case replay_file(path, pubkey_hex) do
            :ok ->
              %{acc | verified: acc.verified + 1}

            {:skip, _reason} ->
              %{acc | skipped: acc.skipped + 1}

            {:error, reason} ->
              %{acc | failed: acc.failed + 1, failures: [reason | acc.failures]}
          end
        end)

      {:error, _} ->
        initial
    end
  end

  @doc """
  Verify a single signed receipt file.
  """
  @spec replay_file(String.t(), String.t()) :: :ok | {:skip, String.t()} | {:error, String.t()}
  def replay_file(path, pubkey_hex) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         %{"kernel_response" => resp} <- data do
      attestation = resp["attestation"]
      signature = resp["signature"]

      cond do
        is_nil(attestation) or attestation == "" ->
          {:skip, "no attestation in #{Path.basename(path)}"}

        is_nil(signature) or signature == "" ->
          {:skip, "no signature in #{Path.basename(path)}"}

        true ->
          if OptimalSystemAgent.Receipt.Verifier.verify(attestation, signature, pubkey_hex) do
            :ok
          else
            {:error, "signature mismatch in #{Path.basename(path)}"}
          end
      end
    else
      _ -> {:error, "could not parse #{Path.basename(path)}"}
    end
  rescue
    e -> {:error, "exception reading #{Path.basename(path)}: #{Exception.message(e)}"}
  end
end
