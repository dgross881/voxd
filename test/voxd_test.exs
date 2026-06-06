defmodule VoxdTest do
  use ExUnit.Case
  doctest Voxd

  test "greets the world" do
    assert Voxd.hello() == :world
  end
end
