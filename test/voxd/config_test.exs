defmodule Voxd.ConfigTest do
  use ExUnit.Case, async: true

  alias Voxd.Config

  doctest Voxd.Config

  @defaults %{
    "ai" => %{
      "model" => "deepseek-r1:14b",
      "ollama_url" => "http://localhost:11434"
    }
  }

  @tag :tmp_dir
  test "missing file returns the defaults", %{tmp_dir: tmp_dir} do
    missing_path = Path.join(tmp_dir, "config.toml")

    assert Config.load(missing_path) == @defaults
  end

  @tag :tmp_dir
  test "user value overrides the matching default", %{tmp_dir: tmp_dir} do
    path = write_config(tmp_dir, ~s([ai]\nmodel = "llama3"\n))

    config = Config.load(path)

    assert config["ai"]["model"] == "llama3"
  end

  @tag :tmp_dir
  test "a user section with one key keeps the other default", %{tmp_dir: tmp_dir} do
    path = write_config(tmp_dir, ~s([ai]\nmodel = "llama3"\n))

    config = Config.load(path)

    assert config["ai"]["ollama_url"] == "http://localhost:11434"
    assert config["ai"]["model"] == "llama3"
  end

  @tag :tmp_dir
  test "an unknown section is preserved alongside defaults", %{tmp_dir: tmp_dir} do
    path = write_config(tmp_dir, ~s([whisper]\ndevice = "cuda"\n))

    config = Config.load(path)

    assert config["whisper"] == %{"device" => "cuda"}
    assert config["ai"] == @defaults["ai"]
  end

  @tag :tmp_dir
  test "invalid TOML raises", %{tmp_dir: tmp_dir} do
    path = write_config(tmp_dir, "this is = not valid = toml")

    assert_raise RuntimeError, fn -> Config.load(path) end
  end

  @spec write_config(String.t(), String.t()) :: String.t()
  defp write_config(tmp_dir, contents) do
    path = Path.join(tmp_dir, "config.toml")
    File.write!(path, contents)
    path
  end
end
