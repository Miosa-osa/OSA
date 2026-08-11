defmodule OptimalSystemAgent.ConfigFileBomTest do
  @moduledoc """
  Same BOM shape as `Settings`, one layer down. `:tomerl`'s lexer has no BOM
  rule (there is no U+FEFF handling anywhere in deps/tomerl/src), and `Jason`
  has none either, so a BOM'd `config.toml` / `config.json` dropped the whole
  overlay — `permissions.deny` and `permissions.catastrophic_patterns`
  included — behind a single warning line.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.ConfigFile

  @bom "﻿"

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_cfg_bom_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, dir)
    ConfigFile.reload()

    on_exit(fn ->
      File.rm_rf(dir)

      if prev,
        do: Application.put_env(:optimal_system_agent, :config_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :config_dir)

      ConfigFile.reload()
    end)

    :ok
  end

  test "a BOM'd config.toml still delivers its deny rules" do
    File.write!(
      ConfigFile.toml_path(),
      @bom <> "[permissions]\ndeny = [\"rm -rf /\"]\n"
    )

    ConfigFile.reload()

    assert ConfigFile.get(["permissions", "deny"]) == ["rm -rf /"],
           "a leading UTF-8 BOM dropped the entire config.toml overlay"
  end

  test "a BOM'd config.json still delivers its model overlay" do
    File.write!(
      ConfigFile.json_path(),
      @bom <> Jason.encode!(%{"model" => "glm-4.7:cloud", "provider" => "zai"})
    )

    ConfigFile.reload()

    assert ConfigFile.get(["model", "model"]) == "glm-4.7:cloud"
    assert ConfigFile.get(["model", "provider"]) == "zai"
  end
end
