defmodule Voxd.Config do
  @moduledoc """
  Reads the voxd TOML config from `~/.config/voxd/config.toml`.

  The result is the built-in defaults with the user's TOML deep-merged over
  them section-by-section: a known section's unspecified keys keep their
  defaults, and unknown sections are added wholesale. A missing file yields
  the defaults; a parse error raises.

  See `priv/config.toml.example` for available options.
  """

  @config_path Path.join([System.user_home!(), ".config", "voxd", "config.toml"])

  @defaults %{
    "ai" => %{
      "model" => "deepseek-r1:14b",
      "ollama_url" => "http://localhost:11434"
    }
  }

  @doc """
  Load the config from the default path (`~/.config/voxd/config.toml`).
  """
  @spec load() :: map()
  def load, do: load(@config_path)

  @doc """
  Load the config from an explicit path. Missing file → defaults; parse error
  raises.
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
