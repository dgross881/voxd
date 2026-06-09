defmodule Voxd.AI do
  @moduledoc """
  The optional "polish my words" step: sends a transcription to a local
  Ollama AI server to fix grammar, punctuation, and filler words. A 1:1 port
  of the Python daemon's `ai.py`. Only used in `"ai"` mode — plain dictation
  never touches this.

  How a call works:

      config = Voxd.Config.load()
      Voxd.AI.cleanup("um so basically the meeting moved to thursday ", config)
      #=> "The meeting moved to Thursday."

  `cleanup/3` POSTs to `{ollama_url}/api/generate` (trailing slash stripped)
  with `stream: false` and a 30-second timeout, sending the exact prompt the
  Python daemon used with the transcription appended. The cleaned text is
  read from the response's `"response"` field and trimmed.

  **This function never raises.** Your words must not be lost because the AI
  is down: an empty response, an error status, a missing field, a connection
  failure, or a timeout each log a warning and return the original `text`
  unchanged — so the pipeline types what you actually said.

  (The example above needs a running Ollama server, so it isn't a doctest;
  the fallback behavior is asserted in `test/voxd/ai_test.exs` with stubbed
  HTTP responses.)
  """

  require Logger

  @prompt "Clean up the following speech transcription. Fix grammar, punctuation, and remove filler words. Keep the same meaning and voice. Output only the cleaned text, nothing else.\n\n"

  @receive_timeout_ms 30_000

  @doc """
  Ask Ollama to clean up `text`, using the `"ai"` section of `config` for
  the model name and server URL (`config["ai"]["model"]`,
  `config["ai"]["ollama_url"]`).

  Returns the polished text on success and the original `text` on any
  failure whatsoever. `req_options` is merged into the `Req` request so
  tests can inject a `plug: {Req.Test, Voxd.AI}` stub.
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
