defmodule OptimalSystemAgent.Security.TypedTextTest do
  @moduledoc """
  The `text` argument of a computer_use/browser typing action is where a
  user's password goes. These tests pin that it is represented by its shape,
  never its value, at every boundary that is not the executor.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.TypedText
  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.UI

  @password "hunter2-correct-horse"

  setup do
    prior = Application.get_env(:optimal_system_agent, :reveal_typed_text)
    System.delete_env("OSA_REVEAL_TYPED_TEXT")
    Application.delete_env(:optimal_system_agent, :reveal_typed_text)

    on_exit(fn ->
      System.delete_env("OSA_REVEAL_TYPED_TEXT")

      if is_nil(prior),
        do: Application.delete_env(:optimal_system_agent, :reveal_typed_text),
        else: Application.put_env(:optimal_system_agent, :reveal_typed_text, prior)
    end)

    :ok
  end

  describe "mask/1" do
    test "replaces the value with its length" do
      assert TypedText.mask("hunter2") == "<7 chars>"
      refute TypedText.mask(@password) =~ "hunter2"
    end

    test "distinguishes empty from nil" do
      assert TypedText.mask("") == "<empty>"
      assert TypedText.mask(nil) == nil
    end

    test "counts characters, not bytes, for multi-byte text" do
      assert TypedText.mask("héllo") == "<5 chars>"
    end
  end

  describe "mask_for_action/2" do
    test "masks typing actions" do
      for action <- ~w(type fill clipboard_set) do
        assert TypedText.mask_for_action(action, @password) == "<21 chars>"
      end
    end

    test "leaves key combos readable — they carry no secret" do
      assert TypedText.mask_for_action("key", "ctrl+c") == "ctrl+c"
      assert TypedText.mask_for_action("click", nil) == nil
    end
  end

  describe "reveal opt-in" do
    test "is off by default" do
      refute TypedText.reveal?()
    end

    test "OSA_REVEAL_TYPED_TEXT=1 exposes the literal text" do
      System.put_env("OSA_REVEAL_TYPED_TEXT", "1")
      assert TypedText.reveal?()
      assert TypedText.mask_for_action("type", @password) == @password
    end
  end

  describe "mask_args/1" do
    test "masks text on a typing action and leaves coordinates alone" do
      masked = TypedText.mask_args(%{"action" => "type", "text" => @password, "x" => 10})

      assert masked["text"] == "<21 chars>"
      assert masked["x"] == 10
      refute inspect(masked) =~ "hunter2"
    end

    test "does not mask text on a non-typing action" do
      masked = TypedText.mask_args(%{"action" => "key", "text" => "ctrl+a"})
      assert masked["text"] == "ctrl+a"
    end

    test "masks nested payloads and credential-named fields" do
      masked =
        TypedText.mask_args(%{
          "input" => %{"selector" => "#pw", "value" => @password},
          "password" => "s3cret!!"
        })

      assert masked["input"]["value"] == "<21 chars>"
      assert masked["input"]["selector"] == "#pw"
      assert masked["password"] == "<8 chars>"
    end
  end

  describe "TUI render map (ComputerUse.UI)" do
    test "typed text is masked before it reaches the PubSub render map" do
      render = UI.render(:tool_use, %{"action" => "type", "text" => @password}, [])

      assert render.text == "<21 chars>"
      refute inspect(render) =~ "hunter2"
    end

    test "key combos stay visible in the render map" do
      render = UI.render(:tool_use, %{"action" => "key", "text" => "ctrl+shift+t"}, [])
      assert render.text == "ctrl+shift+t"
    end
  end
end
