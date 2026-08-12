# NixOS VM test for the signal-whisper module with the Nushell scripts.
#
# Replaces signal-cli/ffmpeg/whisper-cpp with stub binaries (see stubs/)
# and verifies the whole chain end to end inside a VM:
#   preStart installs the LoadCredential secrets into the data dir, the
#   service receives a batch of envelopes (one matching voice note from the
#   linked phone, one plain-text message, one voice note from a stranger),
#   transcribes the matching one and sends "Transcript: ..." back.
{ pkgs }:

let
  stub = name:
    pkgs.writeShellScriptBin name (builtins.readFile ./stubs/${name}.sh);
  # The module bakes `pkgs.signal-cli`/`pkgs.ffmpeg` into its wrapper PATH, so
  # hand it a pkgs built with the stubs via a nixpkgs overlay (a plain
  # `nixpkgs.overlays` on the node never reaches the module's pkgs argument).
  stubPkgs = import pkgs.path {
    inherit (pkgs) system;
    config = { };
    overlays = [
      (final: prev: {
        signal-cli = stub "signal-cli";
        ffmpeg = stub "ffmpeg";
      })
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "signal-whisper-nushell";

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ ../module.nix ];

    _module.args.pkgs = lib.mkForce stubPkgs;

    services.signal-whisper = {
      enable = true;
      model = pkgs.writeText "model.bin" "fake-model";
      whisperPackage = stub "whisper-cli";
      secrets = {
        accountsFile = pkgs.writeText "accounts.json" ''
          {
            "accounts" : [ {
              "path" : "854007",
              "environment" : "LIVE",
              "number" : "+491234567890",
              "uuid" : "aaaaaaaa-0000-0000-0000-000000000001"
            } ],
            "version" : 2
          }
        '';
        accountDbFile = pkgs.writeText "account.db" "secret-db-content";
        accountFile = pkgs.writeText "account" "secret-account";
        # configured in hex, the stub reports it as base64 -> tests the
        # hex<->base64 normalization.
        configFile = pkgs.writeText "config.json" ''
          {
            "account": "+491234567890",
            "groupId": "5d2f0a1b",
            "senders": []
          }
        '';
      };
    };

    system.stateVersion = "24.05";
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("signal-whisper.service")

    # preStart must have installed the secrets into the service data dir
    machine.wait_until_succeeds(
      "test -f /var/lib/signal-whisper/.local/share/signal-cli/data/accounts.json"
    )
    machine.succeed(
      "test -f /var/lib/signal-whisper/.local/share/signal-cli/data/854007.d/account.db"
    )

    # exactly the matching voice note gets transcribed and sent back
    machine.wait_until_succeeds("grep -q 'Transcript: hallo welt' /tmp/send-log.txt")
    machine.succeed("grep -q -- '--notify-self' /tmp/send-log.txt")
    machine.succeed("grep -q -- '-g 5d2f0a1b' /tmp/send-log.txt")
    machine.succeed("test $(grep -c '^CALL:' /tmp/send-log.txt) -eq 1")

    # the service logged the transcription and the unit carries the credentials
    machine.succeed("journalctl -u signal-whisper --no-pager | grep -q 'transcribing voice note'")
    machine.succeed("systemctl show signal-whisper -p LoadCredential | grep -q accounts.json")

    # secrets are only initialized once: restarting the service must not
    # re-install them (signal-cli mutates accounts.json/account.db at runtime).
    machine.succeed("test -f /var/lib/signal-whisper/.signal-whisper-secrets-installed")
    machine.systemctl("restart", "signal-whisper.service")
    machine.wait_for_unit("signal-whisper.service")
    machine.succeed(
      "test $(journalctl -u signal-whisper --no-pager | grep -c 'installed account secrets for') -eq 1"
    )
  '';
}
