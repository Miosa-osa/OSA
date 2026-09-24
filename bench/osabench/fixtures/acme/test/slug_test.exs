defmodule Acme.SlugTest do
  use ExUnit.Case, async: true

  test "slugify lowercases and joins words with dashes" do
    assert Acme.Slug.slugify("Hello World") == "hello-world"
  end

  test "slugify strips punctuation at the edges" do
    assert Acme.Slug.slugify("  Big Sale!! ") == "big-sale"
  end
end
