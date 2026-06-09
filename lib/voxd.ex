defmodule Voxd do
  @moduledoc """
  voxd — a voice-to-text daemon for Linux/Wayland.

  Press a hotkey, talk, press it again (or say "end recording"), and what
  you said is typed into whatever window you have focused. The pieces:

    * `Voxd.Application` boots and supervises everything.
    * `Voxd.Session` runs the record → transcribe → type cycle.
    * `Voxd.CtlSocket` is the Unix socket that control commands (toggle,
      cancel, status) arrive on — the `voxctl` command-line tool is its
      client.
    * `Voxd.Transcriber.Bumblebee` is Whisper on the GPU.
  """
end
