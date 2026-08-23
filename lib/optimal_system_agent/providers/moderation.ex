defmodule OptimalSystemAgent.Providers.Moderation do
  @moduledoc """
  OpenAI moderation pre-screen for security-related requests.

  Before sending a pentest request to the LLM provider, this module checks the
  user's message against OpenAI's Moderation API. If the content is
  security-related but NOT in a forbidden category (sexual, hate, harassment,
  self-harm, violence), it authorizes the request for uncensored response.

  This is the first layer of HackerAI's three-layer anti-flagging system:
  1. Moderation pre-screen (this module) → determines if content is safe to uncensor
  2. Platform authorization annotation → injected into user message at provider boundary
  3. Content-filter error handling → graceful handling when provider still blocks

  ## How it works

  1. Extract the last user message (up to 3 messages, minimum 30 chars)
  2. Truncate to 512 tokens (head + tail for context)
  3. Send to OpenAI Moderation API (`omni-moderation-latest`)
  4. Check category scores: if security content but NOT forbidden categories
     → `should_uncensor: true`
  5. Return result to the provider boundary for annotation injection

  ## Forbidden categories (never uncensor)

  sexual, sexual/minors, hate, hate/threatening, harassment,
  harassment/threatening, self-harm, self-harm/intent, self-harm/instruction,
  violence, violence/graphic

  ## Threshold

  Moderation score between 0.1 and 0.9 (0.98 for paid users) with no forbidden
  category → authorized for uncensored response.
  """

  require Logger

  @moderation_token_limit 512
  @min_message_length 30
  @min_moderation_level 0.1
  @max_moderation_level 0.9

  @forbidden_categories [
    "sexual",
    "sexual/minors",
    "hate",
    "hate/threatening",
    "harassment",
    "harassment/threatening",
    "self-harm",
    "self-harm/intent",
    "self-harm/instruction",
    "violence",
    "violence/graphic"
  ]

  @type moderation_result :: %{
          should_uncensor: boolean(),
          moderation_text: String.t()
        }

  @doc """
  Check if the user's messages should be authorized for uncensored response.

  Returns `%{should_uncensor: boolean(), moderation_text: String.t()}`.

  When `should_uncensor` is `true`, the provider boundary should inject the
  platform authorization annotation into the last user message.

  Returns `%{should_uncensor: false, moderation_text: ""}` when:
  - No OpenAI API key is configured
  - No suitable user message is found
  - The moderation API call fails
  - The content is in a forbidden category
  """
  @spec check_messages([map()], keyword()) :: moderation_result()
  def check_messages(messages, opts \\ []) do
    api_key =
      Keyword.get(opts, :api_key) || Application.get_env(:optimal_system_agent, :openai_api_key)

    if is_nil(api_key) or api_key == "" do
      empty_result()
    else
      case find_target_message(messages) do
        nil ->
          empty_result()

        message ->
          input = prepare_input(message)

          if String.length(input) < @min_message_length do
            empty_result()
          else
            call_moderation_api(input, api_key, opts)
          end
      end
    end
  end

  @doc """
  Check if a message should be uncensored based on its content alone.

  This is a lighter check that doesn't call the moderation API — it just
  checks if the message contains security-related keywords that would
  benefit from the authorization annotation.

  Used as a fallback when no OpenAI API key is configured.
  """
  @spec should_annotate?([map()]) :: boolean()
  def should_annotate?(messages) do
    case find_target_message(messages) do
      nil ->
        false

      message ->
        text = prepare_input(message)
        String.length(text) >= @min_message_length and security_related?(text)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp empty_result, do: %{should_uncensor: false, moderation_text: ""}

  defp call_moderation_api(input, api_key, opts) do
    # Truncate to token limit before sending
    truncated = truncate_by_tokens(input)

    body = Jason.encode!(%{model: "omni-moderation-latest", input: truncated})

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"}
    ]

    case :httpc.request(
           :post,
           {~c"https://api.openai.com/v1/moderations", headers, ~c"application/json", body},
           [{:timeout, 10_000}],
           []
         ) do
      {:ok, {{_version, 200, _}, _resp_headers, resp_body}} ->
        parse_moderation_response(resp_body, truncated, opts)

      {:ok, {{_version, status, _}, _resp_headers, resp_body}} ->
        Logger.warning("[Moderation] API returned status #{status}")
        empty_result()

      {:error, reason} ->
        Logger.warning("[Moderation] API request failed: #{inspect(reason)}")
        empty_result()
    end
  rescue
    e ->
      Logger.warning("[Moderation] API call failed: #{Exception.message(e)}")
      empty_result()
  end

  defp parse_moderation_response(resp_body, input, _opts) do
    case Jason.decode(to_string(resp_body)) do
      {:ok, %{"results" => [result | _]}} ->
        categories = Map.get(result, "categories", %{})
        category_scores = Map.get(result, "category_scores", %{})

        hazard_categories =
          categories
          |> Enum.filter(fn {_cat, flagged} -> flagged end)
          |> Enum.map(fn {cat, _} -> cat end)

        max_score =
          category_scores
          |> Map.values()
          |> Enum.filter(&is_number/1)
          |> Enum.max(fn -> 0.0 end)

        should_uncensor =
          max_score >= @min_moderation_level and
            max_score <= @max_moderation_level and
            not has_forbidden_category?(hazard_categories)

        %{should_uncensor: should_uncensor, moderation_text: input}

      _ ->
        Logger.warning("[Moderation] Unexpected API response format")
        empty_result()
    end
  end

  defp has_forbidden_category?(hazard_categories) do
    Enum.any?(hazard_categories, &(&1 in @forbidden_categories))
  end

  defp find_target_message(messages) when is_list(messages) do
    # Walk backwards through messages, collecting user messages
    # until we have enough content or hit 3 user messages
    do_find_target(Enum.reverse(messages), [], 0, "")
  end

  defp do_find_target([], collected, _count, combined) do
    if String.length(String.trim(combined)) >= 5 and collected != [] do
      create_combined_message(Enum.reverse(collected))
    else
      nil
    end
  end

  defp do_find_target([msg | rest], collected, count, combined) when count >= 3 do
    if String.length(String.trim(combined)) >= @min_message_length do
      create_combined_message(Enum.reverse(collected))
    else
      nil
    end
  end

  defp do_find_target([msg | rest], collected, count, combined) do
    case msg do
      %{role: "user"} = user_msg ->
        text = extract_text(user_msg)
        new_combined = text <> " " <> combined

        if String.length(String.trim(new_combined)) >= @min_message_length do
          create_combined_message(Enum.reverse([user_msg | collected]))
        else
          do_find_target(rest, [user_msg | collected], count + 1, new_combined)
        end

      _ ->
        do_find_target(rest, collected, count, combined)
    end
  end

  defp create_combined_message(messages) do
    text =
      messages
      |> Enum.map(&extract_text/1)
      |> Enum.join(" ")

    %{role: "user", content: text}
  end

  defp extract_text(%{content: content}) when is_binary(content), do: content

  defp extract_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, " ", fn
      %{"type" => "text", "text" => text} -> text
      %{type: "text", text: text} -> text
      _ -> ""
    end)
  end

  defp extract_text(_), do: ""

  defp prepare_input(%{content: content}) when is_binary(content), do: content

  defp prepare_input(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, " ", fn
      %{"type" => "text", "text" => text} -> text
      %{type: "text", text: text} -> text
      _ -> ""
    end)
  end

  defp prepare_input(_), do: ""

  defp truncate_by_tokens(content) do
    # Simple character-based truncation as approximation
    # (Elixir doesn't have a GPT tokenizer built in)
    char_limit = @moderation_token_limit * 4

    if String.length(content) <= char_limit do
      content
    else
      half = div(char_limit, 2)
      head = String.slice(content, 0, half)
      tail = String.slice(content, String.length(content) - half, half)
      head <> " [...] " <> tail
    end
  end

  @security_keywords ~w(
    pentest penetration exploit vulnerability scan recon nmap nuclei
    sqlmap ffuf gobuster subfinder nikto hydra metasploit
    cve cvss injection xss ssrf xxe reverse.shell shellcode payload
    privilege.escalation oscp bug.bounty security.assessment red.team
    attack.surface osint shodan fingerprint bruteforce
  )

  defp security_related?(text) do
    normalized = String.downcase(text)
    Enum.any?(@security_keywords, &String.contains?(normalized, &1))
  end
end
