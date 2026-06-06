import Config

config :voxd,
  transcriber: Voxd.Transcriber.Mock,
  exla_client: :host,
  # The full daemon tree never starts in test; each process is started per-test
  # via start_supervised!. (Application.start/2 reads this.)
  start_daemon?: false
