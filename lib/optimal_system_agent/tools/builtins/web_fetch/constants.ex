defmodule OptimalSystemAgent.Tools.Builtins.WebFetch.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts can reference `tool_name/0` so a rename propagates
  automatically. Mirrors the constants pattern from FileRead.Constants.
  """

  @tool_name "web_fetch"
  def tool_name, do: @tool_name

  @default_max_length 10_000
  def default_max_length, do: @default_max_length

  @max_download_bytes 1_048_576
  def max_download_bytes, do: @max_download_bytes

  @max_redirects 3
  def max_redirects, do: @max_redirects

  # A 2xx response whose extracted text is shorter than this is not content:
  # it is a bot-block interstitial, a JS-only shell, or a redirect stub. Such a
  # fetch is reported to the model as a FAILURE (with the status and the reason)
  # rather than handed back as if it were the page.
  @min_content_chars 40
  def min_content_chars, do: @min_content_chars

  # Sent on every request. Without a browser-shaped UA a large share of hosts
  # answer with a 403 bot-block or an empty shell.
  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
                "Chrome/125.0 Safari/537.36 OSAAgent/1.0"
  def user_agent, do: @user_agent

  @accept "text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.9,*/*;q=0.8"
  def accept, do: @accept
end
