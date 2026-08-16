defmodule OptimalSystemAgent.ToolchainPinTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The toolchain a developer gets, the toolchain CI runs, and the toolchain
  inside the shipped artifact must be the SAME toolchain.

  ## Why this test exists

  For eight releases (v1.0.76 through v1.0.83) they were not. This machine ran
  Elixir 1.19.5 / OTP 28 while `ci.yml` and `release.yml` both pinned 1.17.3 /
  OTP 26.2.5, and there was no `.tool-versions` in the repository — the one
  asdf resolved lived in a parent directory outside the checkout, so it was
  invisible to anyone who cloned and silently different for everyone who did.

  Nothing failed. A locally green "9,535 tests, 0 failures" was reported at
  every release, including by the release gate itself, and every one of those
  numbers was a claim about a toolchain no user ever receives. CI was red on
  all eight runs the whole time. The dominant failure — an ExUnit timeout in
  the circuit-breaker's own bypass regression test — was a real, shipped
  ReDoS in the safety gate (see `DangerousCommands.@fork_bomb`) that simply
  could not be seen from a machine running the wrong OTP.

  So the defect was never any single failing test. It was that the versions
  were allowed to disagree silently. This test is the thing that now fails
  loudly when they drift: it is cheap, it is `async: true`, and it runs in
  every local and CI invocation of the suite.

  It deliberately reads the workflow files as DATA rather than duplicating
  their values here — a constant in this file would be a fourth place to drift.
  """

  @root Path.expand("..", __DIR__)
  @tool_versions Path.join(@root, ".tool-versions")
  @workflows ["ci.yml", "release.yml"]

  # `.tool-versions` -> %{"erlang" => "26.2.5", "elixir" => "1.17.3-otp-26"}
  defp pinned do
    assert File.exists?(@tool_versions),
           """
           .tool-versions is missing from the repository root.

           Without it a clone resolves whatever asdf finds in some parent
           directory, which is how dev, CI and the release artifact came to run
           three different toolchains without anything complaining.
           """

    @tool_versions
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Map.new(fn line ->
      [tool | rest] = String.split(line, ~r/\s+/, trim: true)
      {tool, hd(rest)}
    end)
  end

  # The `env:` block of a workflow -> %{"ELIXIR_VERSION" => ..., "OTP_VERSION" => ...}
  defp workflow_versions(file) do
    path = Path.join([@root, ".github", "workflows", file])
    assert File.exists?(path), "missing workflow: #{path}"
    body = File.read!(path)

    Map.new(["ELIXIR_VERSION", "OTP_VERSION"], fn key ->
      case Regex.run(~r/^\s*#{key}:\s*"([^"]+)"/m, body, capture: :all_but_first) do
        [v] -> {key, v}
        _ -> flunk("#{file} does not set #{key}")
      end
    end)
  end

  defp running_otp_version do
    rel = List.to_string(:erlang.system_info(:otp_release))
    path = Path.join([List.to_string(:code.root_dir()), "releases", rel, "OTP_VERSION"])

    case File.read(path) do
      {:ok, v} -> String.trim(v)
      # Some distro-packaged installs omit the file; fall back to the major.
      {:error, _} -> rel
    end
  end

  test ".tool-versions pins both Erlang and Elixir" do
    p = pinned()

    assert Map.has_key?(p, "erlang"), ".tool-versions does not pin erlang"
    assert Map.has_key?(p, "elixir"), ".tool-versions does not pin elixir"

    # The `-otp-NN` suffix on the Elixir build must name the Erlang we pin,
    # or asdf will happily install an Elixir compiled against a different OTP.
    [otp_major | _] = String.split(p["erlang"], ".")

    assert String.ends_with?(p["elixir"], "-otp-#{otp_major}"),
           """
           .tool-versions pins elixir #{p["elixir"]} against erlang #{p["erlang"]}.
           The Elixir build must be the -otp-#{otp_major} one.
           """
  end

  test "the running toolchain is the pinned toolchain" do
    p = pinned()
    elixir = p["elixir"] |> String.replace(~r/-otp-\d+$/, "")

    assert System.version() == elixir,
           """
           Running Elixir #{System.version()}, but .tool-versions pins #{elixir}.

           A suite that is green here says nothing about the artifact users
           receive. Install the pinned version rather than editing this file:

               asdf install
           """

    assert running_otp_version() == p["erlang"],
           """
           Running OTP #{running_otp_version()}, but .tool-versions pins #{p["erlang"]}.

           This is the exact drift that hid a ReDoS in the safety gate for
           eight releases. Install the pinned version:

               asdf install
           """
  end

  test "CI and the release build use the pinned toolchain" do
    p = pinned()
    elixir = p["elixir"] |> String.replace(~r/-otp-\d+$/, "")

    for file <- @workflows do
      env = workflow_versions(file)

      assert env["ELIXIR_VERSION"] == elixir,
             """
             .github/workflows/#{file} sets ELIXIR_VERSION #{env["ELIXIR_VERSION"]},
             but .tool-versions pins #{elixir}.

             Both must move together — the shipped artifact is built by
             release.yml, so a divergence here means the tested toolchain and
             the released toolchain are different again.
             """

      assert env["OTP_VERSION"] == p["erlang"],
             """
             .github/workflows/#{file} sets OTP_VERSION #{env["OTP_VERSION"]},
             but .tool-versions pins #{p["erlang"]}.
             """
    end
  end

  test "mix.exs admits the pinned Elixir" do
    elixir = pinned()["elixir"] |> String.replace(~r/-otp-\d+$/, "")
    requirement = Keyword.fetch!(Mix.Project.config(), :elixir)

    assert Version.match?(elixir, requirement),
           "mix.exs requires elixir #{requirement}, which excludes the pinned #{elixir}"
  end
end
