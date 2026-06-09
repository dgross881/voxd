defmodule Voxd.PostProcess do
  @moduledoc """
  Cleans up the raw text that comes out of Whisper before it gets typed.

  Whisper gives back exactly what it heard — including the words you said to
  control voxd, like "end recording" or "new paragraph." This module turns
  those spoken commands into real formatting and tidies up the punctuation.
  It is a direct port of the Python daemon's `_post_process`
  (`daemon.py:55-68`): same rules, same order, same output.

  `run/1` applies the rules in this order:

    1. Cut the text off at the first stop phrase ("end recording", "done", …).
    2. Turn spoken formatting commands into the real thing
       ("new paragraph" → a blank line, "open quote" → `“`, …).
    3. Remove newlines at the very start.
    4. Remove stray spaces before punctuation (`hello , world` → `hello, world`).
    5. Capitalize the first letter after a blank line.
    6. Add one trailing space at the end — unless the text is empty or already
       ends in a newline — so back-to-back dictations don't run together.

  Every example in the docs below is a doctest: `mix test` runs them, so the
  documentation cannot drift from what the code actually does.
  """

  @stop_phrase ~r/\b(end\s+(?:recording|dictation|transcription|it|conversation)|stop\s+(?:recording|dictating)|done|end)\b/i

  @commands [
    {~r/\b(?:(?:first|second|third|fourth|fifth|next|new|another)\s+)?paragraph\b[,.]?\s*/i,
     "\n\n"},
    {~r/\b(?:new|next)\s+line[,.]?\s*/i, "\n"},
    {~r/\bline\s+break[,.]?\s*/i, "\n"},
    {~r/\bopen\s+quote\b/i, "“"},
    {~r/\bclose\s+quote\b/i, "”"},
    {~r/\bopen\s+paren(?:thesis)?\b/i, "("},
    {~r/\bclose\s+paren(?:thesis)?\b/i, ")"}
  ]

  @space_before_punctuation ~r/ +([.,!?;:])/
  @lowercase_after_blank_line ~r/(\n\n)([a-z])/
  # 10+ identical characters in a row — the silence-hallucination pattern
  # (e.g. 250 "!" chars). Short punctuation like "..." is NOT repetitive and
  # passes through, matching Python's `if not text.strip()` guard.
  @repetitive_hallucination ~r/(.)\1{9,}/u

  @doc """
  Run the full clean-up pipeline on a raw transcription string.

  Everything after a stop phrase is cut off (the trailing space is the
  standard "ready for the next dictation" suffix):

      iex> Voxd.PostProcess.run("hello world end recording")
      "hello world "

  Spoken formatting commands become real formatting, and the first letter
  after a blank line is capitalized:

      iex> Voxd.PostProcess.run("line one new line line two")
      "line one \\nline two "

      iex> Voxd.PostProcess.run("first part paragraph second part")
      "first part \\n\\nSecond part "

  Stray spaces before punctuation are removed:

      iex> Voxd.PostProcess.run("hello , world !")
      "hello, world! "

  Saying nothing but a stop phrase yields nothing to type:

      iex> Voxd.PostProcess.run("done")
      ""
  """
  @spec run(String.t()) :: String.t()
  def run(text) do
    text
    |> truncate_at_stop_phrase()
    |> apply_commands()
    |> strip_leading_newlines()
    |> remove_spaces_before_punctuation()
    |> capitalize_after_blank_line()
    |> append_trailing_space()
  end

  @doc """
  Whether `text` contains a spoken stop phrase ("end recording", "done",
  "stop dictating", …). The Session's watcher calls this on each short
  audio window to decide whether you just asked the recording to end.

  Whole words only — words that merely *contain* a stop phrase don't count:

      iex> Voxd.PostProcess.stop_phrase?("please end recording")
      true

      iex> Voxd.PostProcess.stop_phrase?("all done")
      true

      iex> Voxd.PostProcess.stop_phrase?("this is endless")
      false
  """
  @spec stop_phrase?(String.t()) :: boolean()
  def stop_phrase?(text), do: Regex.match?(@stop_phrase, text)

  @doc """
  Whether `text` is worth typing at all.

  When the audio was silence or noise, Whisper sometimes "hallucinates" —
  it makes something up rather than returning nothing, typically a long run
  of one repeated character (250 `!` marks was the real-world case). This
  check rejects two things:

  1. Empty or whitespace-only text — mirrors the Python daemon's
     `if not text.strip()`.
  2. Ten or more identical characters in a row — the hallucination pattern.

  Short punctuation like `"..."` is genuine Whisper output on quiet-but-real
  speech and passes through, exactly as it does in Python:

      iex> Voxd.PostProcess.meaningful?("hello world ")
      true

      iex> Voxd.PostProcess.meaningful?("...")
      true

      iex> Voxd.PostProcess.meaningful?("   ")
      false

      iex> Voxd.PostProcess.meaningful?(String.duplicate("!", 250))
      false

  Expects post-processed text (the output of `run/1`); raw Whisper output
  also works since the trailing space is trimmed before checking.
  """
  @spec meaningful?(String.t()) :: boolean()
  def meaningful?(text) do
    trimmed = String.trim(text)
    trimmed != "" and not Regex.match?(@repetitive_hallucination, trimmed)
  end

  @spec truncate_at_stop_phrase(String.t()) :: String.t()
  defp truncate_at_stop_phrase(text) do
    case Regex.run(@stop_phrase, text, return: :index) do
      [{start, _length} | _] -> text |> binary_part(0, start) |> String.trim()
      nil -> text
    end
  end

  @spec apply_commands(String.t()) :: String.t()
  defp apply_commands(text) do
    Enum.reduce(@commands, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  @spec strip_leading_newlines(String.t()) :: String.t()
  defp strip_leading_newlines(text), do: String.trim_leading(text, "\n")

  @spec remove_spaces_before_punctuation(String.t()) :: String.t()
  defp remove_spaces_before_punctuation(text) do
    Regex.replace(@space_before_punctuation, text, "\\1")
  end

  @spec capitalize_after_blank_line(String.t()) :: String.t()
  defp capitalize_after_blank_line(text) do
    Regex.replace(@lowercase_after_blank_line, text, fn _whole, blank_line, letter ->
      blank_line <> String.upcase(letter)
    end)
  end

  @spec append_trailing_space(String.t()) :: String.t()
  defp append_trailing_space(""), do: ""

  defp append_trailing_space(text) do
    case String.ends_with?(text, "\n") do
      true -> text
      false -> text <> " "
    end
  end
end
