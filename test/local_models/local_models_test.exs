defmodule OptimalSystemAgent.LocalModelsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.LocalModels
  alias OptimalSystemAgent.LocalModels.{Catalog, Fit, Hardware, HuggingFace, OllamaAdmin}

  @gib 1024 * 1024 * 1024

  defp hw(overrides \\ %{}) do
    Map.merge(
      Hardware.from_probe(%{
        os: :linux,
        ram_bytes: 64 * @gib,
        cpu: "Intel Core Ultra 9",
        cores: 24,
        nvidia: {"NVIDIA GeForce RTX 5090 Laptop GPU", 24 * @gib}
      }),
      overrides
    )
  end

  describe "Hardware.from_probe/1" do
    test "picks the NVIDIA card and looks up its bandwidth" do
      h = hw()
      assert h.backend == :cuda
      assert h.gpu =~ "5090 Laptop"
      assert h.vram_bytes == 24 * @gib
      assert {896, true} = {h.bandwidth_gbps, h.bandwidth_known}
      assert Hardware.summary(h) == "RTX 5090 Laptop · 24 GB VRAM · 64 GB RAM"
    end

    test "no GPU means CPU backend at CPU bandwidth" do
      h = Hardware.from_probe(%{os: :linux, ram_bytes: 16 * @gib, cpu: "i5"})
      assert h.backend == :cpu
      assert h.vram_bytes == 0
      assert h.bandwidth_gbps == Hardware.cpu_bandwidth_gbps()
    end

    test "Apple Silicon uses 3/4 of unified memory as VRAM" do
      h = Hardware.from_probe(%{os: :macos, ram_bytes: 64 * @gib, apple_chip: "Apple M3 Max"})
      assert h.backend == :metal
      assert h.vram_bytes == 48 * @gib
      assert {400, true} = {h.bandwidth_gbps, h.bandwidth_known}
    end

    test "an unknown GPU gets the default bandwidth, flagged as a guess" do
      h =
        Hardware.from_probe(%{os: :linux, ram_bytes: 32 * @gib, nvidia: {"Tesla P40", 24 * @gib}})

      refute h.bandwidth_known
      assert h.bandwidth_gbps > 0
    end
  end

  describe "Fit.assess/3" do
    setup do
      # The KV-cache term is scaled by the daemon's quantisation
      # (`ollama_kv_cache_type`, baked to "q4_0" by runtime.exs). The fit
      # expectations below are written against the f16 (unscaled) cache, so
      # pin the scale explicitly instead of inheriting the operator's config.
      prev = Application.get_env(:optimal_system_agent, :ollama_kv_cache_type)
      Application.put_env(:optimal_system_agent, :ollama_kv_cache_type, "f16")

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:optimal_system_agent, :ollama_kv_cache_type)
          v -> Application.put_env(:optimal_system_agent, :ollama_kv_cache_type, v)
        end
      end)

      :ok
    end

    test "a 16.5 GB hybrid 27B fits a 24 GB card at 32k ctx and gets a bandwidth-based estimate" do
      f =
        Fit.assess(
          %{weights_bytes: 16_500_000_000, params_b: 27, quant: "Q4_K_M", family: "qwen3.5"},
          hw(),
          32_768
        )

      assert f.verdict == :fits
      assert f.weights_exact
      # 896 GB/s × 0.5 / 16.5 GB ≈ 27 tok/s (measured on this exact setup: 25.6)
      assert_in_delta f.est_tps, 27, 3
      assert f.kv_bytes == 64 * 1024 * 32_768
    end

    test "the same weights as a classic GQA transformer spill at 32k ctx (256 KB/token KV)" do
      f =
        Fit.assess(%{weights_bytes: 16_500_000_000, params_b: 27, quant: "Q4_K_M"}, hw(), 32_768)

      assert f.kv_bytes == 256 * 1024 * 32_768
      assert f.verdict == :partial
    end

    test "a 70B Q4 is a partial offload on 24 GB + 64 GB RAM, and slow" do
      f = Fit.assess(%{params_b: 70, quant: "Q4_K_M"}, hw(), 32_768)
      assert f.verdict == :partial
      refute f.weights_exact
      assert f.gpu_share < 0.6
      assert f.est_tps < 10
    end

    test "nothing fits when weights exceed VRAM + RAM" do
      f = Fit.assess(%{params_b: 400, quant: "Q8_0"}, hw(), 8_192)
      assert f.verdict == :no
      assert f.est_tps == nil
    end

    test "a MoE streams only its active parameters, so it decodes faster than a dense model of the same size" do
      dense = Fit.assess(%{params_b: 35, quant: "Q6_K"}, hw(%{vram_bytes: 48 * @gib}), 8_192)

      moe =
        Fit.assess(
          %{params_b: 35, active_params_b: 3, quant: "Q6_K"},
          hw(%{vram_bytes: 48 * @gib}),
          8_192
        )

      assert moe.est_tps > dense.est_tps * 4
    end

    test "CPU-only boxes get a :cpu verdict when the model fits RAM" do
      cpu = Hardware.from_probe(%{os: :linux, ram_bytes: 32 * @gib})
      assert Fit.assess(%{params_b: 8, quant: "Q4_K_M"}, cpu, 8_192).verdict == :cpu
      assert Fit.assess(%{params_b: 70, quant: "Q4_K_M"}, cpu, 8_192).verdict == :no
    end

    test "exact KV bytes come from GGUF metadata" do
      info = %{
        "general.architecture" => "qwen35",
        "qwen35.block_count" => 64,
        "qwen35.attention.head_count" => 40,
        "qwen35.attention.head_count_kv" => 8,
        "qwen35.embedding_length" => 5120
      }

      assert Fit.kv_from_model_info(info) == 64 * 8 * (128 + 128) * 2
      assert Fit.kv_from_model_info(%{}) == nil

      # Qwen 3.5 27B as Ollama reports it: 64 layers, full attention every 4th,
      # 4 KV heads, 256-dim keys and values -> 64 KB/token.
      hybrid = %{
        "general.architecture" => "qwen35",
        "qwen35.block_count" => 64,
        "qwen35.full_attention_interval" => 4,
        "qwen35.attention.head_count" => 24,
        "qwen35.attention.head_count_kv" => 4,
        "qwen35.attention.key_length" => 256,
        "qwen35.attention.value_length" => 256,
        "qwen35.embedding_length" => 5120
      }

      assert Fit.kv_from_model_info(hybrid) == 64 * 1024
    end
  end

  describe "HuggingFace.parse_repo/1" do
    test "groups split parts per quant and separates the vision projector" do
      body = %{
        "id" => "x/y-GGUF",
        "downloads" => 10,
        "siblings" => [
          %{"rfilename" => "y-Q4_K_M-00001-of-00002.gguf", "size" => 10},
          %{"rfilename" => "y-Q4_K_M-00002-of-00002.gguf", "size" => 5},
          %{"rfilename" => "y.Q8_0.gguf", "size" => 30},
          %{"rfilename" => "mmproj-y-f16.gguf", "size" => 1},
          %{"rfilename" => "README.md", "size" => 99}
        ]
      }

      repo = HuggingFace.parse_repo(body)
      assert repo.mmproj_bytes == 1
      assert [%{quant: "Q4_K_M", bytes: 15}, %{quant: "Q8_0", bytes: 30}] = repo.quants
      assert HuggingFace.quant(repo, "q8_0").bytes == 30
    end

    test "quant_of reads the usual labels" do
      assert HuggingFace.quant_of("Model-Q4_K_M.gguf") == "Q4_K_M"
      assert HuggingFace.quant_of("model.iq4_xs.gguf") == "IQ4_XS"
      assert HuggingFace.quant_of("model-UD-Q2_K_XL.gguf") == "Q2_K"
      assert HuggingFace.quant_of("model-bf16-00001-of-00003.gguf") == "BF16"
      assert HuggingFace.quant_of("mmproj.gguf") == nil
    end
  end

  describe "Catalog" do
    test "ships the curated list and resolves ids, repos and hf.co tags" do
      all = Catalog.all()
      assert length(all) >= 10
      assert Enum.all?(all, &(&1.repo =~ "/" and &1.params_b > 0 and &1.quant != ""))

      e = Catalog.find("superqwen-abliterated")
      assert e.repo == "Jiunsong/SuperQwen3.8-27b-abliterated-GGUF"
      assert Catalog.tag(e) == "hf.co/Jiunsong/SuperQwen3.8-27b-abliterated-GGUF:Q4_K_M"
      assert Catalog.find("hf.co/Jiunsong/SuperQwen3.8-27b-abliterated-GGUF:Q4_K_M") == e
      assert Catalog.find("jiunsong/superqwen3.8-27b-abliterated-gguf") == e
      assert Catalog.find("nope") == nil
    end

    test "user catalog entries merge on top of shipped ones" do
      dir = Path.join(System.tmp_dir!(), "osa-cat-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "local_catalog.json")

      File.write!(
        path,
        Jason.encode!(%{
          "models" => [
            %{"id" => "mine", "repo" => "me/my-GGUF", "params_b" => 4, "quant" => "Q8_0"},
            %{
              "id" => "superqwen-abliterated",
              "repo" => "me/override-GGUF",
              "params_b" => 1,
              "quant" => "Q8_0"
            }
          ]
        })
      )

      Application.put_env(:optimal_system_agent, :local_catalog_user_path, path)

      on_exit(fn ->
        Application.delete_env(:optimal_system_agent, :local_catalog_user_path)
        File.rm_rf(dir)
      end)

      assert %{source: :user, repo: "me/my-GGUF"} = Catalog.find("mine")
      assert %{source: :user, repo: "me/override-GGUF"} = Catalog.find("superqwen-abliterated")
    end
  end

  describe "OllamaAdmin (stubbed daemon)" do
    setup do
      name = :"osa_admin_#{System.unique_integer([:positive])}"
      {:ok, plug: [plug: {Req.Test, name}], name: name}
    end

    test "installed/1 flags cloud tags as remote", %{plug: plug, name: name} do
      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{
          "models" => [
            %{
              "name" => "superqwen-abliterated:latest",
              "size" => 17,
              "details" => %{"quantization_level" => "Q4_K_M", "parameter_size" => "26.9B"}
            },
            %{"name" => "glm-5.2:cloud", "size" => 0, "remote_host" => "https://ollama.com"}
          ]
        })
      end)

      assert {:ok, [local, cloud]} = OllamaAdmin.installed(plug)
      assert %{name: "superqwen-abliterated:latest", quant: "Q4_K_M", remote: false} = local
      assert cloud.remote
    end

    test "installed/1 reads the quant from the tag when Ollama says unknown", %{
      plug: plug,
      name: name
    } do
      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{
          "models" => [
            %{
              "name" => "hf.co/x/y-GGUF:q5_k_m",
              "size" => 1,
              "digest" => "abc",
              "details" => %{"quantization_level" => "unknown"}
            },
            %{
              "name" => "alias:latest",
              "size" => 1,
              "digest" => "abc",
              "details" => %{"quantization_level" => "unknown"}
            }
          ]
        })
      end)

      assert {:ok, [%{quant: "Q5_K_M", digest: "abc"}, %{quant: nil, digest: "abc"}]} =
               OllamaAdmin.installed(plug)
    end

    test "show/2 extracts capabilities and exact KV size", %{plug: plug, name: name} do
      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{
          "capabilities" => ["tools", "vision"],
          "details" => %{"family" => "qwen35", "quantization_level" => "Q4_K_M"},
          "model_info" => %{
            "general.architecture" => "qwen35",
            "general.parameter_count" => 26_895_998_464,
            "qwen35.context_length" => 262_144,
            "qwen35.block_count" => 64,
            "qwen35.attention.head_count" => 40,
            "qwen35.attention.head_count_kv" => 8,
            "qwen35.embedding_length" => 5120
          }
        })
      end)

      assert {:ok, d} = OllamaAdmin.show("x", plug)
      assert d.capabilities == ["tools", "vision"]
      assert d.context_length == 262_144
      assert d.kv_bytes_per_token == 2 * 64 * 8 * 128 * 2
    end

    test "bench/3 converts Ollama's nanosecond timings to tok/s", %{plug: plug, name: name} do
      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{
          "eval_count" => 64,
          "eval_duration" => 2_000_000_000,
          "prompt_eval_count" => 20,
          "prompt_eval_duration" => 100_000_000,
          "load_duration" => 1_500_000_000
        })
      end)

      assert {:ok, %{decode_tps: 32.0, prompt_tps: 200.0, load_ms: 1500}} =
               OllamaAdmin.bench("x", 64, plug)
    end

    test "pull/3 streams progress and reports Ollama errors", %{plug: plug, name: name} do
      Req.Test.stub(name, fn conn ->
        body =
          [
            ~s({"status":"pulling manifest"}),
            ~s({"status":"pulling abc","total":100,"completed":50}),
            ~s({"status":"success"})
          ]
          |> Enum.join("\n")

        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_resp(200, body <> "\n")
      end)

      {:ok, agent} = Agent.start_link(fn -> [] end)
      assert :ok = OllamaAdmin.pull("x", fn ev -> Agent.update(agent, &[ev | &1]) end, plug)
      events = agent |> Agent.get(& &1) |> Enum.reverse()

      assert [%{status: "pulling manifest"}, %{completed: 50, total: 100}, %{status: "success"}] =
               events

      Req.Test.stub(name, fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          ~s({"error":"pull model manifest: file does not exist"}) <> "\n"
        )
      end)

      assert {:error, "pull model manifest: file does not exist"} =
               OllamaAdmin.pull("x", fn _ -> :ok end, plug)
    end

    test "a daemon that is down is an error, not a crash", %{plug: plug, name: name} do
      Req.Test.stub(name, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, msg} = OllamaAdmin.installed(plug)
      assert msg =~ "not running"
    end
  end

  describe "LocalModels.resolve/1" do
    # Point the "local daemon" at a dead port so the real one on this machine
    # cannot turn a catalog id into an installed tag.
    setup do
      prev = Application.get_env(:optimal_system_agent, :ollama_url)
      Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:1")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :ollama_url, prev),
          else: Application.delete_env(:optimal_system_agent, :ollama_url)
      end)

      :ok
    end

    test "catalog ids, hf tags and unknowns" do
      assert {:catalog, %{id: "superqwen-abliterated"}, nil} =
               LocalModels.resolve("superqwen-abliterated")

      assert {:catalog, %{id: "superqwen-abliterated"}, "Q4_K_M"} =
               LocalModels.resolve("hf.co/Jiunsong/SuperQwen3.8-27b-abliterated-GGUF:Q4_K_M")

      assert {:hf, "some/other-GGUF", "Q5_K_M"} =
               LocalModels.resolve("hf.co/some/other-GGUF:Q5_K_M")

      assert {:hf, "some/other-GGUF", nil} = LocalModels.resolve("some/other-GGUF")
      assert :unknown = LocalModels.resolve("")
    end
  end

  describe "note/1" do
    test "summarises fit, speed and capabilities for a picker row" do
      row = %{
        fit: %{verdict: :fits, est_tps: 26.4},
        measured_tps: nil,
        capabilities: ["tools", "vision"],
        size_bytes: 17_200_000_000
      }

      assert LocalModels.note(row) == "✓ fits in VRAM · ~26 tok/s est. · 17.2 GB · tools, vision"
      assert LocalModels.note(%{row | measured_tps: 25.6}) =~ "25.6 tok/s measured"
      assert LocalModels.note(%{row | fit: nil, capabilities: [], size_bytes: 0}) == ""
    end
  end

  describe "kv_cache_scale/0" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :ollama_kv_cache_type)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :ollama_kv_cache_type, prev),
          else: Application.delete_env(:optimal_system_agent, :ollama_kv_cache_type)
      end)

      :ok
    end

    test "a q4_0 KV cache lets SuperQwen's full 262k window fit a 24 GiB card" do
      spec = %{weights_bytes: 17_200_000_000, quant: "Q4_K_M", kv_bytes_per_token: 64 * 1024}
      Application.put_env(:optimal_system_agent, :ollama_kv_cache_type, "f16")
      assert Fit.assess(spec, hw(), 262_144).verdict == :partial
      assert LocalModels.auto_ctx_for(spec, hw(), 262_144) == 65_536

      Application.put_env(:optimal_system_agent, :ollama_kv_cache_type, "q8_0")
      assert LocalModels.auto_ctx_for(spec, hw(), 262_144) == 131_072

      Application.put_env(:optimal_system_agent, :ollama_kv_cache_type, "q4_0")
      assert Fit.assess(spec, hw(), 262_144).verdict == :fits
      assert LocalModels.auto_ctx_for(spec, hw(), 262_144) == 262_144
    end
  end

  describe "auto_ctx_for/3" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :ollama_kv_cache_type)
      Application.put_env(:optimal_system_agent, :ollama_kv_cache_type, "f16")

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:optimal_system_agent, :ollama_kv_cache_type)
          v -> Application.put_env(:optimal_system_agent, :ollama_kv_cache_type, v)
        end
      end)

      :ok
    end

    test "SuperQwen 27B Q4 on a 24 GiB card: 64k fits (17.2 + 4.3 + 1 GB), 96k does not, never below 32k" do
      spec = %{weights_bytes: 17_200_000_000, quant: "Q4_K_M", kv_bytes_per_token: 64 * 1024}
      assert LocalModels.auto_ctx_for(spec, hw(), 262_144) == 65_536
      # A 48 GB card takes the whole trained window's worth up to the cap.
      assert LocalModels.auto_ctx_for(spec, hw(%{vram_bytes: 48 * @gib}), 262_144) == 262_144
      # Capped by the trained window.
      assert LocalModels.auto_ctx_for(spec, hw(%{vram_bytes: 48 * @gib}), 131_072) == 131_072
      # Too big for any bucket still returns the floor rather than nothing.
      assert LocalModels.auto_ctx_for(%{spec | weights_bytes: 23_000_000_000}, hw(), 262_144) ==
               32_768
    end
  end

  describe "to_json/1" do
    test "flattens the catalog entry, stringifies atoms and drops model_info" do
      row = %{
        tag: "hf.co/x:Q4_K_M",
        fit: %{verdict: :fits, est_tps: 26.4, weights_exact: true},
        entry: %{id: "x", blurb: "b", tags: ["t"], repo: "x/y", quants: ["Q4_K_M"], name: "X"},
        model_info: %{"big" => "blob"},
        installed: false
      }

      json = LocalModels.to_json(row)
      assert json.fit.verdict == "fits"
      assert json.catalog_id == "x" and json.repo == "x/y" and json.catalog_quants == ["Q4_K_M"]
      refute Map.has_key?(json, :entry) or Map.has_key?(json, :model_info)
      assert json.installed == false
      assert Jason.encode!(json)
    end
  end

  describe "/models command" do
    test "is registered and prints usage for bad input" do
      assert "models" in Commands.list()
      out = capture_io(fn -> Commands.dispatch("models bogus", "no-session") end)
      assert out =~ "/models install"

      assert capture_io(fn -> Commands.dispatch("models install", "no-session") end) =~
               "/models install"
    end

    test "hardware prints what was detected" do
      out = capture_io(fn -> Commands.dispatch("models hardware", "no-session") end)
      assert out =~ "VRAM"
      assert out =~ "Bandwidth"
    end
  end
end
