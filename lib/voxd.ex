defmodule Voxd do
  @moduledoc """
  Voice-to-text daemon for Linux/Wayland.

  The application is started by `Voxd.Application`. Control commands
  (toggle, cancel, status) are sent over a Unix socket handled by
  `Voxd.Ctl`. See the `voxctl` escript for the CLI client.
  """
end
