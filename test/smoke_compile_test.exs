defmodule SmokeCompileTest do
  use ExUnit.Case, async: false

  test "application boots" do
    # Simply ensure the application supervision tree starts without crashing.
    assert {:ok, _pid} = Application.ensure_all_started(:heaters)
  end
end
