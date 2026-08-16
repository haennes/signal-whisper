# signal-whisper

Transcribe Signal voice notes with whisper and send the transcription back to
a group.

The service registers your phone number as an additional (linked) Signal
device via [signal-cli](https://github.com/AsamK/signal-cli). When you send a
voice note to a dedicated group (from your phone or from any allowed sender),
it is downloaded, transcribed with
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) and the text is sent
back to the group as a normal message.

## How it works

```
phone voice note ──▶ Signal ──▶ signal-cli receive ──▶ ffmpeg ──▶ whisper ──▶ signal-cli send ──▶ group
                                    ▲                    │                       │
                                    │                    └──── "Transcript: ..." ─┘
                    systemd service (services.signal-whisper)
```

A systemd service loops `signal-cli receive`, filters the envelopes to the
configured group and sender, converts audio attachments with ffmpeg, runs
whisper to produce text and sends `Transcript: <text>` back to the group.
Account secrets are injected into the unit via systemd `LoadCredential` and
installed into the service data directory once on first start.

## Packages

This flake provides:

- `packages.<system>.signal-whisper-<model>` – wrapper around whisper.cpp plus
  the model, e.g. `signal-whisper-tiny.en`. Dot characters in the model name
  are replaced by `_` in the flake attribute name (`tiny.en` → `tiny_en`).
- `packages.<system>.<model>` – the raw `ggml-*.bin` model file
  (`tiny_en`, `base`, `small-q5_1`, ...).
- `packages.<system>.signal-whisper-link` – interactive linking tool.
- `nixosModules.default` – the NixOS module.

Supported models are `tiny`, `base`, `small`, `medium`, `large-v1/v2/v3` with
the quantizations published by whisper.cpp (`.en`, `-q5_1`, `-q8_0`, `-q5_0`).

## 1. Link the device (on a trusted machine)

Run the linking tool once on a machine you trust (your phone is needed to scan
the QR code):

```console
nix run .#signal-whisper-link -- +491234567890 ./signal-whisper-secrets
```

It links a new device to your phone number in an isolated data directory,
prints a QR code to scan, lets you pick an existing group or create a new one,
and exports the four secret files:

```
./signal-whisper-secrets/accounts.json
./signal-whisper-secrets/account.db
./signal-whisper-secrets/account
./signal-whisper-secrets/config.json   # account, groupId, senders
```

`config.json` holds the account (phone number), the id of the group to watch
and the list of allowed `senders`. By default only the account's own number is
allowed to trigger a transcription; add other phone numbers to the `senders`
list if you want them to be able to send voice notes as well.

## 2. Configure the module (on the server)

Copy the exported secret files to the server (typically wired to
[agenix](https://github.com/ryantm/agenix)/sops) and enable the module:

```nix
{
  inputs.signal-whisper.url = "github:you/signal-whisper";

  outputs = { nixpkgs, signal-whisper, ... }: {
    nixosConfigurations.myHost = nixpkgs.lib.nixosSystem {
      modules = [
        signal-whisper.nixosModules.default
        ({ pkgs, ... }: {
          services.signal-whisper = {
            enable = true;
            model = pkgs.signal-whisper-tiny-en; # or the model package of your choice
            # language = "auto";   # or e.g. "de"
            # messagePrefix = "Transcript: ";
            # notifySelf = true;
            secrets = {
              accountsFile = "/run/secrets/accounts.json";
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

Note: `model` must be a path to a `ggml-*.bin` file. `pkgs.signal-whisper-tiny-en`
resolves to the `signal-whisper-tiny.en` package of this flake.

## Module options

| Option | Default | Description |
|---|---|---|
| `enable` | `false` | Enable the service. |
| `model` | – | Path to a `ggml-*.bin` whisper model (required). |
| `whisperPackage` | `pkgs.whisper-cpp` | whisper.cpp binary used for transcription. |
| `signalCliPackage` | `pkgs.signal-cli` | signal-cli binary used for the receive/send loop. |
| `dataDir` | `/var/lib/signal-whisper` | Directory holding the service and signal-cli data. |
| `user` | `signal-whisper` | System user the service runs as. |
| `language` | `auto` | Language passed to whisper (`auto` lets it guess). |
| `messagePrefix` | `Transcript: ` | Text prepended to each transcription. |
| `notifySelf` | `true` | Send with `--notify-self` so replies also appear in the phone conversation. |
| `secrets.accountsFile` | `null` | `accounts.json` from the linking tool. |
| `secrets.accountFile` | `null` | `account` from the linking tool. |
| `secrets.accountDbFile` | `null` | `account.db` from the linking tool. |
| `secrets.configFile` | `null` | `config.json` from the linking tool (account, groupId, senders). |

The four `secrets.*` options must be set together. Enabling the module without
secrets emits a warning; the service is started without them.

## Tests

**Transcribe Test Audio from https://etc.usf.edu/lit2go**
The flake ships two checks (`checks.<system>.*`):

- `nushell` – a NixOS VM test that replaces signal-cli/ffmpeg/whisper-cpp with
  stubs and verifies the full chain end to end: secrets installation,
  filtering by group/sender, transcription and reply, and that secrets are
  only installed once across restarts.
- `transcription` – feeds the real `tests/transcribing.mp3` through the
  actual ffmpeg + whisper pipeline and checks the transcribed text.

```console
nix flake check
```


