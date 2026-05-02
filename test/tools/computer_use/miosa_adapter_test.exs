defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.MiosaTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.Miosa

  setup do
    original = Application.get_env(:optimal_system_agent, :computer_use_miosa)

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:optimal_system_agent, :computer_use_miosa)
      else
        Application.put_env(:optimal_system_agent, :computer_use_miosa, original)
      end
    end)

    :ok
  end

  test "available? requires computer id and API key" do
    Application.put_env(:optimal_system_agent, :computer_use_miosa,
      computer_id: "computer-1",
      api_key: "msk_test"
    )

    assert Miosa.available?()

    Application.put_env(:optimal_system_agent, :computer_use_miosa, computer_id: "computer-1")
    refute Miosa.available?()
  end

  test "click posts to the MIOSA desktop click endpoint" do
    parent = self()

    Application.put_env(:optimal_system_agent, :computer_use_miosa,
      computer_id: "computer-1",
      api_key: "msk_test",
      base_url: "https://api.miosa.test/api/v1",
      request: fn method, url, headers, body ->
        send(parent, {:request, method, url, headers, body})
        {:ok, 200, %{"success" => true}}
      end
    )

    assert :ok = Miosa.click(500, 300)

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/click",
                    [{"authorization", "Bearer msk_test"}], %{x: 500, y: 300}}
  end

  test "screenshot region uses the documented region endpoint and saves PNG bytes" do
    parent = self()
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    Application.put_env(:optimal_system_agent, :computer_use_miosa,
      computer_id: "computer-1",
      api_key: "msk_test",
      base_url: "https://api.miosa.test/api/v1",
      request: fn method, url, _headers, body ->
        send(parent, {:request, method, url, body})
        {:ok, 200, png}
      end
    )

    assert {:ok, path} =
             Miosa.screenshot(%{
               "region" => %{"x" => 0, "y" => 0, "width" => 800, "height" => 600}
             })

    assert File.read!(path) == png

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/screenshot/region",
                    %{"x" => 0, "y" => 0, "width" => 800, "height" => 600}}
  end

  test "extended desktop methods use native MIOSA endpoints" do
    parent = self()

    Application.put_env(:optimal_system_agent, :computer_use_miosa,
      computer_id: "computer-1",
      api_key: "msk_test",
      base_url: "https://api.miosa.test/api/v1",
      request: fn method, url, _headers, body ->
        send(parent, {:request, method, url, body})
        {:ok, 200, %{"ok" => true}}
      end
    )

    assert :ok = Miosa.right_click(%{"action" => "right_click", "x" => 10, "y" => 20})
    assert :ok = Miosa.triple_click(%{"target" => "@e1"})
    assert :ok = Miosa.set_value(%{"target" => "@e2", "text" => "value"})
    assert :ok = Miosa.clipboard_set("copied")
    assert :ok = Miosa.clipboard_clear()
    assert :ok = Miosa.resize_window(%{"window_id" => "w1", "width" => 800, "height" => 600})
    assert :ok = Miosa.move_window(%{"window_id" => "w1", "x" => 1, "y" => 2})
    assert :ok = Miosa.scroll_to(%{"target" => "@e3"})

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/right-click",
                    %{"x" => 10, "y" => 20}}

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/triple-click",
                    %{"target" => "@e1"}}

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/set-value",
                    %{"target" => "@e2", "text" => "value"}}

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/clipboard",
                    %{text: "copied"}}

    assert_receive {:request, :delete,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/clipboard", nil}

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/window/resize",
                    %{"window_id" => "w1", "width" => 800, "height" => 600}}

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/window/move",
                    %{"window_id" => "w1", "x" => 1, "y" => 2}}

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/scroll-to",
                    %{"target" => "@e3"}}
  end

  test "observation methods return MIOSA response bodies" do
    parent = self()

    Application.put_env(:optimal_system_agent, :computer_use_miosa,
      computer_id: "computer-1",
      api_key: "msk_test",
      base_url: "https://api.miosa.test/api/v1",
      request: fn method, url, _headers, body ->
        send(parent, {:request, method, url, body})
        {:ok, 200, [%{"id" => "item-1"}]}
      end
    )

    assert {:ok, [%{"id" => "item-1"}]} = Miosa.snapshot(%{"compact" => true})
    assert {:ok, [%{"id" => "item-1"}]} = Miosa.clipboard_get()
    assert {:ok, [%{"id" => "item-1"}]} = Miosa.list_apps()
    assert {:ok, [%{"id" => "item-1"}]} = Miosa.list_surfaces(%{"window_id" => "w1"})

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/snapshot",
                    %{"compact" => true}}

    assert_receive {:request, :get,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/clipboard", nil}

    assert_receive {:request, :get,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/apps", nil}

    assert_receive {:request, :post,
                    "https://api.miosa.test/api/v1/computers/computer-1/desktop/surfaces",
                    %{"window_id" => "w1"}}
  end
end
