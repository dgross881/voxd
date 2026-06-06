defmodule Voxd.AI do
  @moduledoc """
  Optional AI cleanup of a transcription via a local Ollama server, a 1:1 port of
  the Python daemon's `ai.py`.

  `cleanup/3` POSTs to `{ollama_url}/api/generate` (trailing slash stripped) with
  `stream: false` and a 30 s receive timeout, sending the exact Python prompt with
  the transcription substituted. The cleaned text is read from the response's
  `"response"` field and trimmed.

  This function **never raises**: an empty response, a non-200 status, a missing
  field, a connection error, or a timeout all log a warning and return the
  original `text` unchanged.
  """

  require Logger

  @prompt "Clean up the following speech transcription. Fix grammar, punctuation, and remove filler words. Keep the same meaning and voice. Output only the cleaned text, nothing else.\n\n"

  @receive_timeout_ms 30_000

  @doc """
  Clean up `text` using the Ollama config in `config` (`config["ai"]["model"]`
  and `config["ai"]["ollama_url"]`).

  `req_options` is merged into the `Req` request so tests can inject a
  `plug: {Req.Test, Voxd.AI}` stub. On any failure the original `text` is
  returned.
  """
  @spec cleanup(String.t(), map(), keyword()) :: String.t()
  def cleanup(text, config, req_options \\ []) do
    ai_config = Map.fetch!(config, "ai")
    url = generate_url(ai_config)
    body = request_body(ai_config, text)

    [url: url, json: body, receive_timeout: @receive_timeout_ms]
    |> Keyword.merge(req_options)
    |> Req.post()
    |> extract_cleaned(text)
  end

  @spec generate_url(map()) :: String.t()
  defp generate_url(ai_config) do
    String.trim_trailing(Map.fetch!(ai_config, "ollama_url"), "/") <> "/api/generate"
  end

  @spec request_body(map(), String.t()) :: map()
  defp request_body(ai_config, text) do
    %{
      "model" => Map.fetch!(ai_config, "model"),
      "prompt" => @prompt <> text,
      "stream" => false
    }
  end

  @spec extract_cleaned({:ok, Req.Response.t()} | {:error, Exception.t()}, String.t()) ::
          String.t()
  defp extract_cleaned({:ok, %Req.Response{status: 200, body: %{"response" => response}}}, text) do
    keep_or_fallback(String.trim(response), text)
  end

  defp extract_cleaned({:ok, %Req.Response{status: 200}}, text) do
    Logger.warning("ai: Ollama response missing \"response\" field, using original text")
    text
  end

  defp extract_cleaned({:ok, %Req.Response{status: status}}, text) do
    Logger.warning("ai: Ollama returned status #{status}, using original text")
    text
  end

  defp extract_cleaned({:error, exception}, text) do
    Logger.warning(
      "ai: Ollama unavailable (#{Exception.message(exception)}), using original text"
    )

    text
  end

  @spec keep_or_fallback(String.t(), String.t()) :: String.t()
  defp keep_or_fallback("", text) do
    Logger.warning("ai: Ollama returned empty response, using original")
    text
  end

  defp keep_or_fallback(cleaned, _text), do: cleaned
end
