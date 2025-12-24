defmodule MarketmailerTest do
  use ExUnit.Case
  doctest Marketmailer

  test "greets the world" do
    assert Marketmailer.hello() == :world
  end
end
