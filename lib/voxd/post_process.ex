defmodule Voxd.PostProcess do
  @moduledoc """
  Pure transcription clean-up, ported 1:1 from the Python daemon's
  `_post_process` (`daemon.py:55-68`).

  The pipeline, in order:

    1. Truncate at the first stop phrase (`end recording`, `done`, …).
    2. Replace spoken formatting commands (`new paragraph`, `open quote`, …).
    3. Strip leading newlines.
    4. Remove spaces before `.,!?;:`.
    5. Capitalize the first letter after a blank line.
    6. Append one trailing space unless the text is empty or ends in a newline.
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
  @letter_or_digit ~r/[\p{L}\p{N}]/u

  @doc """
  Run the full clean-up pipeline on a raw transcription string.
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
  Whether `text` contains a stop phrase (`end recording`, `done`, `stop
  dictating`, …). Used by the Session's watcher to decide when a spoken
  command should end the recording.
  """
  @spec stop_phrase?(String.t()) :: boolean()
  def stop_phrase?(text), do: Regex.match?(@stop_phrase, text)

  @doc """
  Whether `text` contains at least one letter or digit (any script).

  Whisper hallucinates strings of pure punctuation (e.g. 250 `!` characters)
  on silent audio; such output must be treated as "nothing heard", never
  typed into the focused window.
  """
  @spec meaningful?(String.t()) :: boolean()
  def meaningful?(text), do: Regex.match?(@letter_or_digit, text)

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
