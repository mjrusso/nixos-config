# Hosts the guest reaches directly rather than through the egress proxy
# (NO_PROXY). None of them needs a credential the proxy supplies.
[
  # The guest itself. Some dev servers publish their 0.0.0.0 bind address
  # rather than localhost.
  "localhost"
  "127.0.0.1"
  "0.0.0.0"
  "::1"
  # ONNX Runtime's prebuilt binaries, which the `ort` crate's build script
  # downloads with a built-in root store, so it doesn't trust the egress CA.
  "cdn.pyke.io"
]
