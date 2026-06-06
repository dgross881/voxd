defmodule Voxd.PostProcessTest do
  use ExUnit.Case, async: true

  alias Voxd.PostProcess

  @curly_open "“"
  @curly_close "”"

  describe "run/1 — table-driven port of daemon.py:_post_process" do
    # {description, input, expected}
    cases = [
      # --- stop-phrase truncation (cut at match start, strip; pipeline then
      #     appends the standard trailing space to the non-empty remainder) ---
      {"end recording truncates and strips", "hello world end recording", "hello world "},
      {"stop dictating truncates", "take this note stop dictating now", "take this note "},
      {"bare done truncates", "buy milk done", "buy milk "},
      {"bare end truncates", "that is all end", "that is all "},
      {"end it truncates", "wrap up end it please", "wrap up "},
      {"end conversation truncates", "goodbye end conversation", "goodbye "},
      {"stop recording truncates", "save this stop recording", "save this "},
      {"end transcription truncates", "final words end transcription", "final words "},
      {"stop phrase is case-insensitive", "all set DONE", "all set "},

      # --- stop phrase must respect word boundaries (no mid-word truncation) ---
      {"trend recording does not truncate (no \\b before end)", "the trend recording shows.",
       "the trend recording shows. "},
      {"abandoned does not truncate on bare end/done substring", "we abandoned the plan today.",
       "we abandoned the plan today. "},

      # --- spoken command replacements (leading whitespace before the command
      #     is preserved; only the trailing [,.]?\s* / \b is consumed) ---
      {"plain paragraph -> blank line", "first part paragraph second part",
       "first part \n\nSecond part "},
      {"new paragraph variant", "intro new paragraph body", "intro \n\nBody "},
      {"next paragraph variant", "intro next paragraph body", "intro \n\nBody "},
      {"another paragraph variant", "intro another paragraph body", "intro \n\nBody "},
      {"third paragraph variant", "intro third paragraph body", "intro \n\nBody "},
      {"new line command", "line one new line line two", "line one \nline two "},
      {"next line command", "line one next line line two", "line one \nline two "},
      {"line break command", "line one line break line two", "line one \nline two "},
      {"open and close quote", "she said open quote hi close quote loudly",
       "she said #{@curly_open} hi #{@curly_close} loudly "},
      {"open and close paren", "value open paren x close paren done", "value ( x ) "},
      {"parenthesis longform", "note open parenthesis aside close parenthesis end",
       "note ( aside ) "},

      # --- command followed by comma / period is consumed by [,.]?\s* suffix ---
      {"new line followed by comma", "alpha new line, beta", "alpha \nbeta "},
      {"paragraph followed by period", "alpha paragraph. beta", "alpha \n\nBeta "},

      # --- whitespace / punctuation cleanup ---
      {"space before punctuation removed", "hello , world !", "hello, world! "},
      {"multiple spaces before punctuation removed", "wait   ; now", "wait; now "},
      {"leading newlines stripped", "\n\nhello", "hello "},

      # --- capitalize lowercase letter after blank line ---
      {"capitalize after blank line", "one paragraph two", "one \n\nTwo "},

      # --- trailing-space rule (both branches) ---
      {"non-empty not ending in newline gets one trailing space", "hi", "hi "},
      {"text ending in newline gets no trailing space (new line at end)", "body new line",
       "body \n"},
      {"empty input stays empty", "", ""},
      {"text that is only a stop phrase becomes empty", "done", ""}
    ]

    for {description, input, expected} <- cases do
      @input input
      @expected expected
      test description do
        assert PostProcess.run(@input) == @expected
      end
    end
  end

  describe "meaningful?/1 — hallucination guard" do
    test "text with letters is meaningful" do
      assert PostProcess.meaningful?("hello world ")
    end

    test "text with only digits is meaningful" do
      assert PostProcess.meaningful?("42 ")
    end

    test "non-latin letters are meaningful" do
      assert PostProcess.meaningful?("привет ")
    end

    test "punctuation-only hallucination is not meaningful" do
      refute PostProcess.meaningful?(String.duplicate("!", 250) <> " ")
    end

    test "whitespace and mixed punctuation are not meaningful" do
      refute PostProcess.meaningful?("  ... !!! ??? ")
      refute PostProcess.meaningful?("")
    end
  end

  describe "stop_phrase?/1 — watcher stop detection" do
    stop_cases = [
      {"end recording", "please end recording"},
      {"end dictation", "end dictation"},
      {"end transcription", "okay end transcription"},
      {"end it", "now end it"},
      {"end conversation", "end conversation"},
      {"stop recording", "stop recording"},
      {"stop dictating", "stop dictating"},
      {"bare done", "all done"},
      {"bare end", "the end"}
    ]

    for {description, input} <- stop_cases do
      @stop_input input
      test "true for #{description}" do
        assert PostProcess.stop_phrase?(@stop_input)
      end
    end

    no_stop_cases = [
      {"ordinary speech", "this is a normal sentence"},
      {"empty string", ""},
      {"endless is not end (word boundary)", "this is endless"},
      {"pretend is not end", "let us pretend"}
    ]

    for {description, input} <- no_stop_cases do
      @nostop_input input
      test "false for #{description}" do
        refute PostProcess.stop_phrase?(@nostop_input)
      end
    end
  end
end
