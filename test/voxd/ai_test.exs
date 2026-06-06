defmodule Voxd.AITest do
  use ExUnit.Case, async: true

  alias Voxd.AI

  @config %{"ai" => %{"model" => "deepseek-r1:14b", "ollama_url" => "http://localhost:11434"}}

  @prompt_prefix "Clean up the following speech transcription. Fix grammar, punctuation, and remove filler words. Keep the same meaning and voice. Output only the cleaned text, nothing else.\n\n"

  defp req_options, do: [plug: {Req.Test, Voxd.AI}]

  describe "cleanup/3 success" do
    test "returns the trimmed cleaned text from the response field" do
      Req.Test.stub(Voxd.AI, fn conn ->
        Req.Test.json(conn, %{"response" => "  Cleaned up text.  "})
      end)

      assert AI.cleanup("um cleaned up text", @config, req_options()) == "Cleaned up text."
    end

    test "posts model, exact prompt with text, and stream: false" do
      Req.Test.stub(Voxd.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = JSON.decode!(raw)

        assert body["model"] == "deepseek-r1:14b"
        assert body["stream"] == false
        assert body["prompt"] == @prompt_prefix <> "raw words"

        Req.Test.json(conn, %{"response" => "ok"})
      end)

      assert AI.cleanup("raw words", @config, req_options()) == "ok"
    end

    test "strips a trailing slash on ollama_url before appending /api/generate" do
      Req.Test.stub(Voxd.AI, fn conn ->
        assert conn.request_path == "/api/generate"
        Req.Test.json(conn, %{"response" => "ok"})
      end)

      slashed = %{"ai" => %{"model" => "m", "ollama_url" => "http://localhost:11434/"}}
      assert AI.cleanup("x", slashed, req_options()) == "ok"
    end
  end

  describe "cleanup/3 fallbacks to original text" do
    test "empty response returns the original text" do
      Req.Test.stub(Voxd.AI, fn conn ->
        Req.Test.json(conn, %{"response" => "   "})
      end)

      assert AI.cleanup("original", @config, req_options()) == "original"
    end

    test "non-200 status returns the original text" do
      Req.Test.stub(Voxd.AI, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert AI.cleanup("original", @config, req_options()) == "original"
    end

    test "missing response field returns the original text" do
      Req.Test.stub(Voxd.AI, fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert AI.cleanup("original", @config, req_options()) == "original"
    end

    test "connection error returns the original text" do
      Req.Test.stub(Voxd.AI, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert AI.cleanup("original", @config, req_options()) == "original"
    end
  end
end
