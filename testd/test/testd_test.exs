defmodule TestdTest do
  use ExUnit.Case
  doctest Testd

  test "greets the world" do
    assert Testd.hello() == :world
  end
end
