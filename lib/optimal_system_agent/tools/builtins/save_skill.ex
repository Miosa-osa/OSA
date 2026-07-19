defmodule OptimalSystemAgent.Tools.Builtins.SaveSkill do
  @moduledoc """
  Record a verified, reusable procedure into the Voyager-style skill library.

  The agent calls this after it has *confirmed* a procedure works, so the
  knowledge compounds across sessions and projects. Retrieve saved skills later
  with the `find_skill` tool.

  Flat-layout tool: implements `name/0`, `description/0`, `parameters/0`,
  `execute/1` on top of the defaults injected by `Tools.Behaviour`.
  """

  use OptimalSystemAgent.Tools.Behaviour

  require Logger

  alias OptimalSystemAgent.Store.SkillLibrary

  @impl true
  def name, do: "save_skill"

  @impl true
  def safety, do: :write_safe

  @impl true
  def search_hint,
    do: "record remember store a verified reusable procedure skill how-to recipe for later"

  @impl true
  def description do
    "Save a verified, reusable procedure to the persistent skill library so it " <>
      "can be reused in future sessions and projects. Call this only AFTER you have " <>
      "confirmed the procedure actually works, and only for GENERALISABLE know-how " <>
      "worth recalling later — not trivial one-offs, and not a paraphrase of the title. " <>
      "A skill is rejected unless it has a descriptive title, a real when_to_use trigger " <>
      "(so it can be matched to future tasks), and a substantive body of concrete steps. " <>
      "Provide title, description, when_to_use (the trigger), and body (the steps or code)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{
          "type" => "string",
          "description" => "Short human-readable name for the skill, e.g. 'Restart OSA gateway'"
        },
        "description" => %{
          "type" => "string",
          "description" => "One or two sentences describing what the procedure accomplishes"
        },
        "when_to_use" => %{
          "type" => "string",
          "description" => "The situation/trigger that makes this skill relevant"
        },
        "body" => %{
          "type" => "string",
          "description" => "The verified procedure: numbered steps, commands, or code"
        },
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Keywords for retrieval, e.g. ['gateway', 'ops']"
        },
        "slug" => %{
          "type" => "string",
          "description" =>
            "Optional stable id; derived from the title when omitted. Re-saving the " <>
              "same slug updates the skill in place and preserves its use count."
        }
      },
      "required" => ["title", "body"]
    }
  end

  @impl true
  def execute(args) when is_map(args) do
    case SkillLibrary.save_skill(args) do
      {:ok, skill} ->
        {:ok,
         "Saved skill '#{skill["title"]}' (slug: #{skill["slug"]}). " <>
           "It will be retrievable via find_skill in future sessions."}

      {:error, reason} ->
        {:error, "Could not save skill: #{reason}"}
    end
  rescue
    e -> {:error, "save_skill error: #{Exception.message(e)}"}
  end

  def execute(_), do: {:error, "save_skill expects an object of arguments"}
end
