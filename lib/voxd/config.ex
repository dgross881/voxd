defmodule Voxd.Config do
  @moduledoc """
  Loads voxd's settings from `~/.config/voxd/config.toml`.

  Settings the user leaves out fall back to built-in defaults: the file is
  merged over the defaults one section at a time, so omitting a key from a
  section keeps that key's default, and any extra sections the user adds are
  kept as-is. No settings file at all simply means "use the defaults" —
  which is exactly what loading a path that doesn't exist returns:

      iex> Voxd.Config.load("/nonexistent/config.toml")
      %{"ai" => %{"model" => "deepseek-r1:14b", "ollama_url" => "http://localhost:11434"}}

  A file that exists but can't be parsed raises an error instead of silently
  running with wrong settings.

  See `priv/config.toml.example` for every available option.
  """

  @config_path Path.join([System.user_home!(), ".config", "voxd", "config.toml"])

  @defaults %{
    "ai" => %{
      "model" => "deepseek-r1:14b",
      "ollama_url" => "http://localhost:11434"
    }
  }

  @doc """
  Load the settings from the default path (`~/.config/voxd/config.toml`).
  """
  @spec load() :: map()
  def load, do: load(@config_path)

  @doc """
  Load the settings from an explicit path. A missing file returns the
  defaults; a file that won't parse raises.
  """
  @spec load(String.t()) :: map()
  def load(path) do
    case File.exists?(path) do
      true -> merge_user_over_defaults(decode!(path))
      false -> @defaults
    end
  end

  @spec decode!(String.t()) :: map()
  defp decode!(path) do
    case Toml.decode_file(path) do
      {:ok, user_config} -> user_config
      {:error, reason} -> raise "invalid config TOML at #{path}: #{inspect(reason)}"
    end
  end

  @spec merge_user_over_defaults(map()) :: map()
  defp merge_user_over_defaults(user_config) do
    Enum.reduce(user_config, @defaults, &merge_section/2)
  end

  @spec merge_section({String.t(), map()}, map()) :: map()
  defp merge_section({section, user_values}, config) do
    merged_section = Map.merge(Map.get(config, section, %{}), user_values)
    Map.put(config, section, merged_section)
  end
end
