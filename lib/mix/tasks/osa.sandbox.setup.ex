defmodule Mix.Tasks.Osa.Sandbox.Setup do
  @shortdoc "Set up the OSA Docker sandbox (build image, create workspace, verify)"

  @moduledoc """
  Prepares the OSA Docker sandbox environment.

  ## What this task does

  1. Checks that Docker is installed and the daemon is running
  2. Builds (or rebuilds) the `osa-sandbox:latest` image from `sandbox/Dockerfile`
  3. Creates `~/.osa/workspace` on the host if it does not exist
  4. Runs a smoke test to confirm the image works correctly
  5. Prints a summary with next steps

  ## Usage

      mix osa.sandbox.setup

  ## Options

  - `--no-cache`   Force a full image rebuild ignoring Docker's build cache
  - `--image NAME` Use a custom image tag instead of `osa-sandbox:latest`
  - `--skip-test`  Skip the smoke-test container run

  ## Enabling the sandbox

  After setup completes, enable the sandbox in one of two ways:

      # Environment variable (recommended for production)
      export OSA_SANDBOX_ENABLED=true

      # Or in config/dev.exs
      config :optimal_system_agent, sandbox_enabled: true

  ## Security model

  The sandbox wraps every skill shell command in a Docker container with:
    - Read-only root filesystem
    - No network by default
    - All Linux capabilities dropped
    - Non-root user (UID 1000)
    - 256 MB memory limit, 0.5 CPU limit
    - Automatic cleanup (--rm)

  This is defence-in-depth on top of the existing blocklist checks in
  `ShellExecute`.
  """

  use Mix.Task

  @default_image "osa-sandbox:latest"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [no_cache: :boolean, image: :string, skip_test: :boolean],
        aliases: []
      )

    image = Keyword.get(opts, :image, @default_image)
    no_cache = Keyword.get(opts, :no_cache, false)
    skip_test = Keyword.get(opts, :skip_test, false)

    Mix.shell().info("")
    Mix.shell().info("OSA Sandbox Setup")
    Mix.shell().info("=================")
    Mix.shell().info("")

    with :ok <- check_docker(),
         :ok <- build_image(image, no_cache),
         :ok <- create_workspace(),
         :ok <- maybe_smoke_test(image, skip_test) do
      print_success(image)
    else
      {:error, reason} ->
        Mix.shell().error("")
        Mix.shell().error("Setup failed: #{reason}")
        Mix.shell().error("")
        System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp check_docker do
    Mix.shell().info("Step 1/4 — Checking Docker...")

    case docker("info", []) do
      {_out, 0} ->
        Mix.shell().info("  Docker daemon is running.")
        :ok

      {out, _code} ->
        excerpt = out |> String.split("\n") |> Enum.take(3) |> Enum.join(" ")
        {:error, "Docker not available or daemon not running. Output: #{excerpt}"}
    end
  end

  defp build_image(image, no_cache) do
    Mix.shell().info("")
    Mix.shell().info("Step 2/4 — Building image #{image}...")

    # Locate sandbox/Dockerfile relative to the mix project root
    dockerfile_dir = Path.join(mix_project_root(), "sandbox")
    dockerfile_path = Path.join(dockerfile_dir, "Dockerfile")

    if not File.exists?(dockerfile_path) do
      {:error,
       "sandbox/Dockerfile not found at #{dockerfile_path}. " <>
         "Make sure you are running this from the project root."}
    else
      cache_flag = if no_cache, do: ["--no-cache"], else: []

      build_args = ["build", "-t", image, dockerfile_dir] ++ cache_flag

      Mix.shell().info("  Running: docker #{Enum.join(build_args, " ")}")

      # Stream output so the user sees build progress
      port =
        Port.open(
          {:spawn_executable, System.find_executable("docker")},
          [
            {:args, build_args},
            :stream,
            :binary,
            :exit_status,
            :stderr_to_stdout
          ]
        )

      exit_code = stream_port(port)

      if exit_code == 0 do
        Mix.shell().info("  Image #{image} built successfully.")
        :ok
      else
        {:error, "docker build exited with code #{exit_code}"}
      end
    end
  end

  defp create_workspace do
    Mix.shell().info("")
    Mix.shell().info("Step 3/4 — Creating workspace directory...")

    workspace = Path.expand("~/.osa/workspace")

    case File.mkdir_p(workspace) do
      :ok ->
        Mix.shell().info("  Workspace: #{workspace}")
        :ok

      {:error, reason} ->
        {:error, "Could not create workspace #{workspace}: #{inspect(reason)}"}
    end
  end

  defp maybe_smoke_test(_image, true) do
    Mix.shell().info("")
    Mix.shell().info("Step 4/4 — Smoke test skipped (--skip-test)")
    :ok
  end

  defp maybe_smoke_test(image, false) do
    Mix.shell().info("")
    Mix.shell().info("Step 4/4 — Running smoke test...")

    workspace = Path.expand("~/.osa/workspace")

    smoke_args = [
      "run",
      "--rm",
      "--network",
      "none",
      "--memory",
      "128m",
      "--cpus",
      "0.5",
      "--read-only",
      "--tmpfs",
      "/tmp:rw,noexec,nosuid,size=16m",
      "--security-opt",
      "no-new-privileges:true",
      "--cap-drop",
      "ALL",
      "-v",
      "#{workspace}:/workspace:rw",
      "-w",
      "/workspace",
      "-u",
      "1000:1000",
      image,
      "sh",
      "-c",
      "echo 'OSA sandbox OK' && whoami && id"
    ]

    case docker_args(smoke_args) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.each(fn line -> Mix.shell().info("  #{line}") end)

        Mix.shell().info("  Smoke test passed.")
        :ok

      {output, code} ->
        {:error, "Smoke test failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  defp print_success(image) do
    Mix.shell().info("")
    Mix.shell().info("Setup complete!")
    Mix.shell().info("")
    Mix.shell().info("To enable the sandbox:")
    Mix.shell().info("  export OSA_SANDBOX_ENABLED=true")
    Mix.shell().info("")
    Mix.shell().info("Or in config/dev.exs:")
    Mix.shell().info("  config :optimal_system_agent, sandbox_enabled: true")
    Mix.shell().info("")
    Mix.shell().info("Image:     #{image}")
    Mix.shell().info("Workspace: #{Path.expand("~/.osa/workspace")}")
    Mix.shell().info("")
    Mix.shell().info("Run `mix osa.sandbox.setup --help` for more options.")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp docker(subcommand, extra_args) do
    docker_args([subcommand | extra_args])
  end

  defp docker_args(args) do
    try do
      System.cmd("docker", args, stderr_to_stdout: true)
    rescue
      e -> {Exception.message(e), 1}
    end
  end

  defp mix_project_root do
    # Mix.Project.build_path returns something like /path/to/_build/dev
    # We want the project root which is two levels up
    Mix.Project.build_path()
    |> Path.dirname()
    |> Path.dirname()
  end

  # Drain a Port and return its exit status.
  defp stream_port(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        stream_port(port)

      {^port, {:exit_status, code}} ->
        code
    end
  end
end
