defmodule OptimalSystemAgent.LocalModels.Fit do
  @moduledoc """
  Will a model run on this hardware, and roughly how fast?

  Pure arithmetic over a model spec and a `Hardware.t()`:

    * **weights** — the GGUF bytes (exact when known from HF / the daemon,
      else `params × bytes-per-param(quant)`)
    * **KV cache** — per-token bytes × context length
    * **overhead** — ~1 GiB for the runtime, compute buffers, the projector

  Verdicts:

    * `:fits`    — everything sits in VRAM (or unified memory)
    * `:partial` — weights spill into system RAM; runs, but decode drops to
                   CPU bandwidth for the spilled share
    * `:cpu`     — no GPU; runs from RAM at CPU speed
    * `:no`      — does not fit in VRAM + RAM at all

  The tokens/sec number is an ESTIMATE from memory bandwidth — decode streams
  the active weights once per token — with a ~65% efficiency factor that
  matches what llama.cpp actually achieves on consumer cards. `Bench` replaces
  it with a measured figure once the model is installed.
  """

  alias OptimalSystemAgent.LocalModels.Hardware

  @type spec :: %{
          optional(:weights_bytes) => non_neg_integer() | nil,
          optional(:params_b) => number() | nil,
          optional(:active_params_b) => number() | nil,
          optional(:quant) => String.t() | nil,
          optional(:kv_bytes_per_token) => non_neg_integer() | nil
        }

  @type verdict :: :fits | :partial | :cpu | :no

  @type t :: %{
          verdict: verdict(),
          weights_bytes: non_neg_integer(),
          kv_bytes: non_neg_integer(),
          total_bytes: non_neg_integer(),
          budget_bytes: non_neg_integer(),
          gpu_share: float(),
          est_tps: float() | nil,
          ctx: pos_integer(),
          weights_exact: boolean()
        }

  @overhead 1024 * 1024 * 1024
  # Measured: SuperQwen 3.8 27B Q4_K_M on an RTX 5090 Laptop (896 GB/s,
  # 17.2 GB) decodes at 25.6 tok/s = 49% of the bandwidth-bound ceiling.
  @efficiency 0.5
  # A MoE streams only its active experts, but the router, shared experts and
  # attention still cost — measured throughput is roughly half the naive
  # active/total scaling predicts.
  @moe_efficiency 0.5
  # Leave headroom for the display / compositor and driver allocations.
  @vram_usable 0.92
  @ram_usable 0.70

  # Bytes per parameter by quant. GGUF K-quants mix block sizes, so these are
  # measured whole-file averages, not the nominal bit width.
  @bytes_per_param %{
    "IQ1_S" => 0.22,
    "IQ1_M" => 0.24,
    "IQ2_XXS" => 0.27,
    "IQ2_XS" => 0.30,
    "IQ2_S" => 0.31,
    "IQ2_M" => 0.34,
    "Q2_K" => 0.40,
    "Q2_K_L" => 0.42,
    "IQ3_XXS" => 0.39,
    "IQ3_XS" => 0.42,
    "IQ3_S" => 0.44,
    "IQ3_M" => 0.46,
    "Q3_K" => 0.49,
    "Q3_K_S" => 0.44,
    "Q3_K_M" => 0.49,
    "Q3_K_L" => 0.53,
    "IQ4_XS" => 0.54,
    "Q4_0" => 0.57,
    "Q4_K_S" => 0.58,
    "Q4_K" => 0.61,
    "Q4_K_M" => 0.61,
    "Q4_K_L" => 0.63,
    "Q5_0" => 0.69,
    "Q5_K_S" => 0.70,
    "Q5_K" => 0.72,
    "Q5_K_M" => 0.72,
    "Q5_K_L" => 0.74,
    "Q6_K" => 0.83,
    "Q8_0" => 1.07,
    "MXFP4" => 0.55,
    "F16" => 2.0,
    "BF16" => 2.0,
    "F32" => 4.0
  }

  @doc "Bytes per parameter for a quant label (case-insensitive); Q4_K_M when unknown."
  @spec bytes_per_param(String.t() | nil) :: float()
  def bytes_per_param(nil), do: @bytes_per_param["Q4_K_M"]

  def bytes_per_param(quant) do
    Map.get(@bytes_per_param, String.upcase(quant), @bytes_per_param["Q4_K_M"])
  end

  @doc "Bytes the weights take: exact when the spec carries them, else estimated."
  @spec weights_bytes(spec()) :: {non_neg_integer(), boolean()}
  def weights_bytes(%{weights_bytes: bytes}) when is_integer(bytes) and bytes > 0,
    do: {bytes, true}

  def weights_bytes(%{params_b: params} = spec) when is_number(params) and params > 0 do
    {round(params * 1.0e9 * bytes_per_param(Map.get(spec, :quant))), false}
  end

  def weights_bytes(_), do: {0, false}

  @doc """
  KV-cache bytes per token. Exact from GGUF metadata when the spec has it.

  Otherwise a rule of thumb. Hybrid architectures (Qwen 3.5/3.6, Gemma 4,
  the linear-attention + sliding-window families) keep a full KV cache on
  only a fraction of their layers — measured 64 KB/token on Qwen 3.5 27B —
  so they get ~64 KB. Classic GQA transformers (Llama 3, Qwen 3, Mistral;
  8 KV heads × 128 dims, f16) get ~128 KB/token under 20B params, ~256 KB
  above, ~320 KB above 60B.
  """
  @spec kv_bytes_per_token(spec()) :: non_neg_integer()
  def kv_bytes_per_token(%{kv_bytes_per_token: n}) when is_integer(n) and n > 0, do: n

  def kv_bytes_per_token(spec) do
    family = spec |> Map.get(:family) |> to_string() |> String.downcase()

    cond do
      hybrid_family?(family) ->
        64 * 1024

      true ->
        case Map.get(spec, :params_b) do
          p when is_number(p) and p >= 60 -> 320 * 1024
          p when is_number(p) and p >= 20 -> 256 * 1024
          _ -> 128 * 1024
        end
    end
  end

  @hybrid_families ~w(qwen35 qwen3.5 qwen36 qwen3.6 qwen3.8 gemma4 lfm2 deepseek)
  defp hybrid_family?(family), do: Enum.any?(@hybrid_families, &String.starts_with?(family, &1))

  @doc """
  How much of the f16 KV cache the daemon actually allocates, from
  `:ollama_kv_cache_type` (mirrors `OLLAMA_KV_CACHE_TYPE` on the Ollama
  service): f16 → 1.0, q8_0 → 0.5, q4_0 → 0.25.
  """
  @spec kv_cache_scale() :: float()
  def kv_cache_scale do
    case Application.get_env(:optimal_system_agent, :ollama_kv_cache_type, "f16") do
      "q8_0" -> 0.5
      "q4_0" -> 0.25
      "q4_1" -> 0.28
      "q5_0" -> 0.34
      "q5_1" -> 0.38
      _ -> 1.0
    end
  end

  @doc "From GGUF `model_info` (Ollama `/api/show`): exact KV bytes per token, or nil."
  @spec kv_from_model_info(map()) :: non_neg_integer() | nil
  def kv_from_model_info(info) when is_map(info) do
    arch = info["general.architecture"]

    with true <- is_binary(arch),
         layers when is_integer(layers) <- info["#{arch}.block_count"],
         heads when is_integer(heads) and heads > 0 <- info["#{arch}.attention.head_count"],
         emb when is_integer(emb) <- info["#{arch}.embedding_length"] do
      kv_heads = info["#{arch}.attention.head_count_kv"] || heads
      key_len = info["#{arch}.attention.key_length"] || div(emb, heads)
      value_len = info["#{arch}.attention.value_length"] || key_len

      # Hybrid models (Qwen 3.5+: gated DeltaNet on 3 of every 4 layers) only
      # keep a KV cache on the full-attention layers.
      kv_layers =
        case info["#{arch}.full_attention_interval"] do
          i when is_integer(i) and i > 1 -> div(layers, i)
          _ -> layers
        end

      # K and V, f16.
      kv_layers * kv_heads * (key_len + value_len) * 2
    else
      _ -> nil
    end
  end

  def kv_from_model_info(_), do: nil

  @doc "Assess `spec` on `hw` at `ctx` tokens of context."
  @spec assess(spec(), Hardware.t(), pos_integer()) :: t()
  def assess(spec, hw, ctx) when is_integer(ctx) and ctx > 0 do
    {weights, exact} = weights_bytes(spec)
    kv = round(kv_bytes_per_token(spec) * ctx * kv_cache_scale())
    total = weights + kv + @overhead

    vram_budget = round(hw.vram_bytes * @vram_usable)
    ram_budget = round(hw.ram_bytes * @ram_usable)

    {verdict, gpu_share, budget} =
      cond do
        weights == 0 ->
          {:no, 0.0, vram_budget}

        hw.backend == :cpu ->
          if total <= ram_budget, do: {:cpu, 0.0, ram_budget}, else: {:no, 0.0, ram_budget}

        total <= vram_budget ->
          {:fits, 1.0, vram_budget}

        total <= vram_budget + ram_budget ->
          # KV and overhead stay on the GPU; weights spill.
          on_gpu = max(vram_budget - kv - @overhead, 0)
          {:partial, min(on_gpu / weights, 1.0), vram_budget}

        true ->
          {:no, 0.0, vram_budget}
      end

    %{
      verdict: verdict,
      weights_bytes: weights,
      kv_bytes: kv,
      total_bytes: total,
      budget_bytes: budget,
      gpu_share: Float.round(gpu_share * 1.0, 2),
      est_tps: estimate_tps(spec, weights, gpu_share, verdict, hw),
      ctx: ctx,
      weights_exact: exact
    }
  end

  # tokens/s ≈ bandwidth ÷ bytes streamed per token. For a MoE only the
  # active experts stream, so scale by active/total params. A partial offload
  # is a harmonic blend: the GPU share at GPU bandwidth, the rest at CPU.
  defp estimate_tps(_spec, _w, _share, :no, _hw), do: nil
  defp estimate_tps(_spec, 0, _share, _v, _hw), do: nil

  defp estimate_tps(spec, weights, share, verdict, hw) do
    active_bytes = weights * active_fraction(spec)
    cpu_bw = Hardware.cpu_bandwidth_gbps() * 1.0e9 * @efficiency
    gpu_bw = hw.bandwidth_gbps * 1.0e9 * @efficiency

    seconds_per_token =
      case verdict do
        :cpu -> active_bytes / cpu_bw
        :fits -> active_bytes / gpu_bw
        :partial -> active_bytes * share / gpu_bw + active_bytes * (1 - share) / cpu_bw
      end

    Float.round(1 / seconds_per_token, 1)
  end

  defp active_fraction(%{active_params_b: a, params_b: p})
       when is_number(a) and is_number(p) and p > 0 and a > 0 and a < p,
       do: a / p / @moe_efficiency

  defp active_fraction(_), do: 1.0

  @doc "Human label for a verdict."
  @spec label(verdict()) :: String.t()
  def label(:fits), do: "fits in VRAM"
  def label(:partial), do: "partial offload (slow)"
  def label(:cpu), do: "CPU only"
  def label(:no), do: "won't fit"
end
