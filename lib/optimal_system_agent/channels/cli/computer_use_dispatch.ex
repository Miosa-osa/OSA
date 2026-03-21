defmodule OptimalSystemAgent.Channels.CLI.ComputerUseDispatch do
  @moduledoc """
  Smart computer-use dispatch for the CLI REPL.

  Performs a lightweight LLM call with only the computer_use and launch_app
  tools to classify the user's intent and extract action parameters (~3 s on
  Ollama). Falls back to the full agent loop when the intent doesn't match.
  """

  @reset IO.ANSI.reset()
  @dim IO.ANSI.faint()

  @cu_keywords ~w(
    screenshot click type key press scroll move mouse drag
    tela print captura clica digita aperta scrolla rola mova
    cursor botão button element tree accessibility árvore elementos
  )

  @doc "Returns true when the input looks like a computer-use command."
  def intent?(input) do
    lower = String.downcase(input)
    Enum.any?(@cu_keywords, &String.contains?(lower, &1))
  end

  @doc "Dispatch a computer-use input: classify via LLM, execute each tool call."
  def dispatch(input, _session_id) do
    IO.write("#{@dim}  ⚡ scanning screen…#{@reset}")

    screen_context =
      case OptimalSystemAgent.Tools.Builtins.ComputerUse.execute(%{"action" => "get_tree"}) do
        {:ok, tree} ->
          tree
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "[e"))
          |> Enum.take(30)
          |> Enum.join("\n")

        _ ->
          "(no elements available)"
      end

    clear_line()
    IO.write("#{@dim}  ⚡ understanding…#{@reset}")

    case classify_and_dispatch(input, screen_context) do
      {:ok, tool_calls} when tool_calls != [] ->
        Enum.each(tool_calls, fn {tool_name, params} ->
          clear_line()
          IO.write("#{@dim}  ⚡ #{tool_name}#{format_multi_params(tool_name, params)}#{@reset}")
          result = execute_multi_tool(tool_name, params)
          clear_line()
          IO.puts("#{IO.ANSI.green()}  ✓ #{result}#{@reset}")
        end)

      {:ok, []} ->
        clear_line()
        IO.puts("#{@dim}  ? Couldn't determine actions#{@reset}")

      {:error, reason} ->
        clear_line()
        IO.puts("#{IO.ANSI.red()}  ✗ #{reason}#{@reset}")
    end
  end

  # Single unified LLM call — classifies AND extracts params for all tools.
  defp classify_and_dispatch(input, screen_context \\ "") do
    url = cu_api_url()
    key = cu_api_key()
    model = cu_model()

    tools = [
      %{
        type: "function",
        function: %{
          name: "launch_app",
          description:
            "Launch/open an application. For URLs pass as args (e.g. app=firefox, args=google.com)",
          parameters: %{
            type: "object",
            properties: %{
              app: %{type: "string", description: "App name (firefox, nautilus, gnome-text-editor)"},
              args: %{type: "string", description: "Arguments like a URL"}
            },
            required: ["app"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "computer_use",
          description:
            "Desktop action: screenshot, click, double_click, type, key, scroll, move_mouse, drag, get_tree. Set window param to focus a window first.",
          parameters: %{
            type: "object",
            properties: %{
              action: %{
                type: "string",
                enum: [
                  "screenshot",
                  "click",
                  "double_click",
                  "type",
                  "key",
                  "scroll",
                  "move_mouse",
                  "drag",
                  "get_tree"
                ]
              },
              x: %{type: "integer"},
              y: %{type: "integer"},
              text: %{type: "string"},
              direction: %{type: "string", enum: ["up", "down", "left", "right"]},
              target: %{type: "string"},
              window: %{type: "string"}
            },
            required: ["action"]
          }
        }
      }
    ]

    screen_info =
      if screen_context != "" and screen_context != "(no elements available)",
        do: "\n\nCurrent screen elements:\n#{screen_context}",
        else: ""

    messages = [
      %{
        role: "system",
        content: """
        You control a Linux desktop with two tools.
        IMPORTANT: "press/type/scroll/click IN app" means use computer_use WITH window="app name". NEVER launch_app for these.
        - launch_app: ONLY when user says "open" or "launch" an app. Never for press/type/click/scroll.
        - computer_use actions:
          type: text="hello", window="Firefox" | key: text="ctrl+t", window="Firefox" | click: target="e5" or x=N,y=N | screenshot | get_tree | scroll: direction="down", window="Firefox"
        #{screen_info}
        """
      },
      %{role: "user", content: input}
    ]

    body = Jason.encode!(%{model: model, messages: messages, tools: tools, max_tokens: 8192})
    headers = [{"authorization", "Bearer #{key}"}, {"content-type", "application/json"}]

    case Req.post(url, body: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]}}} ->
        tcs = msg["tool_calls"] || []

        if tcs != [] do
          calls =
            Enum.map(tcs, fn tc ->
              name = tc["function"]["name"]
              {:ok, args} = Jason.decode(tc["function"]["arguments"])
              {name, args}
            end)

          {:ok, calls}
        else
          {:ok, []}
        end

      {:ok, %{status: s, body: b}} ->
        {:error, "LLM returned #{s}: #{inspect(String.slice(inspect(b), 0, 200))}"}

      {:error, r} ->
        {:error, inspect(r)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_multi_tool("launch_app", %{"app" => app} = params) do
    args = params["args"] || ""
    cmd_args = if args != "", do: String.split(args), else: []
    spawn(fn -> System.cmd("nohup", [app | cmd_args], stderr_to_stdout: true) end)
    Process.sleep(2000)
    "Launched #{app} #{args}"
  rescue
    e -> "Error: #{Exception.message(e)}"
  end

  defp execute_multi_tool("computer_use", params) do
    case OptimalSystemAgent.Tools.Builtins.ComputerUse.execute(params) do
      {:ok, {:image, %{path: p}}} -> "Screenshot: #{p}"
      {:ok, msg} when is_binary(msg) -> msg
      {:ok, other} -> inspect(other)
      {:error, reason} -> "Error: #{reason}"
    end
  end

  defp execute_multi_tool(name, _params), do: "Unknown tool: #{name}"

  defp format_multi_params("launch_app", %{"app" => app} = p), do: " #{app} #{p["args"] || ""}"
  defp format_multi_params("computer_use", params), do: format_cu_params(params)
  defp format_multi_params(_, _), do: ""

  defp format_cu_params(%{"action" => "click", "x" => x, "y" => y}), do: " (#{x}, #{y})"
  defp format_cu_params(%{"action" => "double_click", "x" => x, "y" => y}), do: " (#{x}, #{y})"
  defp format_cu_params(%{"action" => "move_mouse", "x" => x, "y" => y}), do: " → (#{x}, #{y})"
  defp format_cu_params(%{"action" => "type", "text" => t}), do: " \"#{String.slice(t, 0, 30)}\""
  defp format_cu_params(%{"action" => "key", "text" => t}), do: " #{t}"
  defp format_cu_params(%{"action" => "scroll", "direction" => d}), do: " #{d}"
  defp format_cu_params(%{"action" => "get_tree"}), do: " (accessibility)"
  defp format_cu_params(_), do: ""

  defp cu_api_url do
    url = Application.get_env(:optimal_system_agent, :ollama_url) || "https://ollama.com"
    "#{url}/v1/chat/completions"
  end

  defp cu_api_key do
    Application.get_env(:optimal_system_agent, :ollama_api_key) || ""
  end

  defp cu_model do
    Application.get_env(:optimal_system_agent, :ollama_model) || "nemotron-3-super:cloud"
  end

  defp clear_line do
    width =
      case :io.columns() do
        {:ok, cols} -> cols
        _ -> 80
      end

    IO.write("\r#{String.duplicate(" ", width)}\r")
  end
end
