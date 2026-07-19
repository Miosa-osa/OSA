defmodule OptimalSystemAgent.Skills.RankerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Skills.Ranker

  @now ~U[2026-07-19 12:00:00Z]

  defp skill(attrs) do
    Map.merge(
      %{
        "slug" => "s",
        "title" => "",
        "description" => "",
        "when_to_use" => "",
        "body" => "",
        "tags" => [],
        "uses" => 0,
        "updated_at" => DateTime.to_iso8601(@now)
      },
      attrs
    )
  end

  describe "relevance gate" do
    test "a skill that does not match the query never surfaces, however recent/used" do
      hot = skill(%{"slug" => "hot", "title" => "quantum widget", "uses" => 999})
      match = skill(%{"slug" => "match", "title" => "restart the gateway"})

      ranked = Ranker.rank([hot, match], "restart gateway", now: @now)

      assert Enum.map(ranked, & &1["slug"]) == ["match"]
    end

    test "empty query returns nothing" do
      assert Ranker.rank([skill(%{"title" => "anything"})], "", now: @now) == []
    end
  end

  describe "field-weighted relevance" do
    test "a title match outranks a body-only match" do
      title_hit = skill(%{"slug" => "title", "title" => "deploy the gateway"})
      body_hit = skill(%{"slug" => "body", "body" => "incidentally we also deploy things here"})

      ranked = Ranker.rank([body_hit, title_hit], "deploy", now: @now)

      assert Enum.map(ranked, & &1["slug"]) == ["title", "body"]
    end

    test "fuzzy prefix match: query token matches a longer word" do
      s = skill(%{"slug" => "dep", "title" => "deployment runbook"})
      assert [%{"slug" => "dep"}] = Ranker.rank([s], "deploy", now: @now)
    end
  end

  describe "recency boost (relevance equal)" do
    test "the more recently updated skill ranks higher" do
      old =
        skill(%{
          "slug" => "old",
          "title" => "restart gateway",
          "updated_at" => DateTime.to_iso8601(DateTime.add(@now, -90, :day))
        })

      fresh =
        skill(%{
          "slug" => "fresh",
          "title" => "restart gateway",
          "updated_at" => DateTime.to_iso8601(@now)
        })

      ranked = Ranker.rank([old, fresh], "restart gateway", now: @now)
      assert Enum.map(ranked, & &1["slug"]) == ["fresh", "old"]
    end
  end

  describe "usage boost (relevance and recency equal)" do
    test "the more-used skill ranks higher" do
      rare = skill(%{"slug" => "rare", "title" => "restart gateway", "uses" => 0})
      popular = skill(%{"slug" => "popular", "title" => "restart gateway", "uses" => 15})

      ranked = Ranker.rank([rare, popular], "restart gateway", now: @now)
      assert Enum.map(ranked, & &1["slug"]) == ["popular", "rare"]
    end
  end

  describe "limit" do
    test "returns at most :limit results" do
      skills =
        for i <- 1..10, do: skill(%{"slug" => "s#{i}", "title" => "gateway task #{i}"})

      assert length(Ranker.rank(skills, "gateway", limit: 3, now: @now)) == 3
    end
  end

  describe "relevance/2" do
    test "scores matching text above zero and non-matching text at zero" do
      assert Ranker.relevance("restart the gateway safely", "gateway") > 0.0
      assert Ranker.relevance("something unrelated", "gateway") == 0.0
      assert Ranker.relevance("", "gateway") == 0.0
      assert Ranker.relevance("gateway", "") == 0.0
    end
  end
end
