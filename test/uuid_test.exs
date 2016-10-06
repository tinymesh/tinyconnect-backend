defmodule PluginTTYTest do
  use ExUnit.Case, async: false


  test "uuid" do
    assert nil != :uuid.uuid
    assert :uuid.uuid != :uuid.uuid
  end
end
