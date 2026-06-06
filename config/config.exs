import Config

config :exla, :clients,
  cuda: [platform: :cuda, preallocate: false, memory_fraction: 0.5],
  host: [platform: :host]

config :voxd,
  transcriber: Voxd.Transcriber.Bumblebee,
  exla_client: :cuda

import_config "#{config_env()}.exs"
