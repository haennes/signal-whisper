# signal-whisper

Transcribe Signal voice notes with whisper and send the transcription back to
a group.

The service registers your phone number as an additional (linked) Signal
device via [signal-cli](https://github.com/AsamK/signal-cli). Voice notes from
any sender, received in direct messages or groups, are transcribed with
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) and sent back to the
selected group as a normal message.

## How it works

```
phone voice note ──▶ Signal ──▶ signal-cli receive ──▶ ffmpeg ──▶ whisper ──▶ signal-cli send ──▶ group
                                    ▲                    │                       │
                                    │                    └──── transcription ────┘
                    systemd service (services.signal-whisper)
```

A systemd service loops `signal-cli receive`, converts audio attachments with
ffmpeg, runs whisper to produce text and sends it to the configured group. The
service has audio length and rate limits; notes sent or forwarded to the
selected group bypass them.
Account secrets are injected into the unit via systemd `LoadCredential` and
installed into the service data directory once on first start.

## Packages

This flake provides:

- `packages.<system>.signal-whisper-<model>` – wrapper around whisper.cpp plus
  the model, e.g. `signal-whisper-tiny_en`. Dot characters in the model name
  are replaced by `_` in the flake attribute name (`tiny.en` → `tiny_en`).
- `packages.<system>.<model>` – the raw model package, containing the
  `ggml-*.bin` file
  (`tiny_en`, `base`, `small-q5_1`, ...).
- `packages.<system>.signal-whisper-link` – interactive linking tool.
- `nixosModules.default` – the NixOS module.

Supported models are `tiny`, `base`, `small`, `medium`, `large-v1/v2/v3` with
the quantizations published by whisper.cpp (`.en`, `-q5_1`, `-q8_0`, `-q5_0`).

## 1. Link the device (on a trusted machine)

Run the linking tool once on a machine you trust (your phone is needed to scan
the QR code):

```bash
nix run .#signal-whisper-link -- +491234567890 ./signal-whisper-secrets
```

It links a new device to your phone number in an isolated data directory,
prints a QR code to scan, lets you pick an existing group or create a new one,
and exports the four secret files:

```
./signal-whisper-secrets/accounts.json
./signal-whisper-secrets/account.db
./signal-whisper-secrets/account
./signal-whisper-secrets/config.json   # account, groupId
```

`config.json` holds the account (phone number) and selected group id. Existing
`senders` fields are ignored.

## 2. Configure the module (on the server)

Copy the exported secret files to the server (typically wired to
[agenix](https://github.com/ryantm/agenix)/sops) and enable the module:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    signal-whisper = {
      url = "github:haennes/signal-whisper";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, signal-whisper, ... }: {
    nixosConfigurations.myHost = nixpkgs.lib.nixosSystem {
      modules = [
        signal-whisper.nixosModules.default
        ({ pkgs, ... }: {
          services.signal-whisper = {
            enable = true;
            modelName = "tiny.en"; # or e.g. "base-q5_1"
            # language = "auto";   # or e.g. "de"
            # messagePrefix = "Voice note — ";
            # notifySelf = true;
            secrets = {
              accountsFile = "/run/secrets/accounts.json";
              # The db's user and group must match signal-whisper's.
              # All other secrets may be owned by any user and group.
              accountDbFile = "/run/secrets/account.db";
              accountFile = "/run/secrets/account";
              configFile = "/run/secrets/config.json";
            };
          };
        })
      ];
    };
  };
}
```

Set exactly one of `modelName` (a model package name such as `tiny.en`) or
`model` (a path to a `ggml-*.bin` file).

## Module options

| Option | Default | Description |
|---|---|---|
| `enable` | `false` | Enable the service. |
| `modelName` | – | Name of a model package provided by this flake, e.g. `tiny.en`. |
| `model` | – | Path to a `ggml-*.bin` whisper model; mutually exclusive with `modelName`. |
| `whisperPackage` | `pkgs.whisper-cpp` | whisper.cpp binary used for transcription. |
| `signalCliPackage` | `pkgs.signal-cli` | signal-cli binary used for the receive/send loop. |
| `dataDir` | `/var/lib/signal-whisper` | Directory holding the service and signal-cli data. |
| `user` | `signal-whisper` | System user the service runs as. |
| `language` | `auto` | Language passed to whisper (`auto` lets it guess). |
| `messagePrefix` | `""` | Optional text prepended to the sender and group header. |
| `notifySelf` | `true` | Send with `--notify-self` so replies also appear in the phone conversation. |
| `maxAudioLengthSeconds` | `120` | Maximum voice-message duration outside the selected group. |
| `secrets.accountsFile` | `null` | `accounts.json` from the linking tool. |
| `secrets.accountFile` | `null` | `account` from the linking tool. |
| `secrets.accountDbFile` | `null` | `account.db` from the linking tool. |
| `secrets.configFile` | `null` | `config.json` from the linking tool (account and groupId). |

The four `secrets.*` options must be set together. Enabling the module without
secrets emits a warning; the service is started without them.

## Tests

**Transcribe Test Audio from https://etc.usf.edu/lit2go**
The flake ships two checks (`checks.<system>.*`):

- `nushell` – a NixOS VM test that replaces signal-cli/ffmpeg/whisper-cpp with
  stubs and verifies the full chain end to end: secrets installation,
  all-sender transcription, length and rate limits, selected-group bypass,
  notifications, and that secrets are only installed once across restarts.
- `transcription` – feeds the real `tests/transcribing.mp3` through the
  actual ffmpeg + whisper pipeline and checks the transcribed text.

```console
nix flake check
```
