# NixOS VM test for the signal-whisper module with the Nushell scripts.
#
# Replaces signal-cli/ffmpeg/whisper-cpp with stub binaries (see stubs/)
# and verifies the whole chain end to end inside a VM:
#   preStart installs the LoadCredential secrets into the data dir, the
#   service receives messages from any sender, enforces duration and rate
#   limits outside the selected group, and routes replies and notices there.
{ pkgs }:

let
  stub = name: pkgs.writeShellScriptBin name (builtins.readFile ./stubs/${name}.sh);
  ffprobe = pkgs.writeShellScriptBin "ffprobe" ''
    input="''${@: -1}"
    if [[ "$input" == *voice-long* || "$input" == *voice-a-id* ]]; then echo 121; else echo 30; fi
  '';
  modelPackages = import ../modelPackages.nix {
    inherit pkgs;
    lib = pkgs.lib;
    name = "signal-whisper";
  };
  modelPath = "${modelPackages.tiny_en}/${modelPackages.tiny_en.name}.bin";
  # The module still bakes `pkgs.ffmpeg` into its wrapper PATH, so hand it a
  # pkgs built with the stubs via a nixpkgs overlay (a plain `nixpkgs.overlays`
  # on the node never reaches the module's pkgs argument). signal-cli and
  # whisper-cpp are injected through the module's *Package options instead.
  stubPkgs = import pkgs.path {
    inherit (pkgs) system;
    config = { };
    overlays = [
      (final: prev: {
        ffmpeg = pkgs.symlinkJoin {
          name = "ffmpeg-stubs";
          paths = [ (stub "ffmpeg") ffprobe ];
        };
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
      modelName = "tiny_en";
      whisperPackage = stub "whisper-cli";
      signalCliPackage = stub "signal-cli";
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
    machine.succeed("test -f '${modelPath}'")
    machine.succeed("grep -Fq 'SIGNAL_WHISPER_MODEL=${modelPath}' /etc/systemd/system/signal-whisper.service")

    # preStart must have installed the secrets into the service data dir
    machine.wait_until_succeeds(
      "test -f /var/lib/signal-whisper/.local/share/signal-cli/data/accounts.json"
    )
    machine.succeed(
      "test -f /var/lib/signal-whisper/.local/share/signal-cli/data/854007.d/account.db"
    )

    # Any sender can trigger five transcriptions per hour outside the selected
    # group; the next request is blocked. Group names and sender names are
    # included in the reply header, and the selected group bypasses the limits.
    machine.wait_until_succeeds("grep -q 'hallo welt' /tmp/send-log.txt")
    machine.succeed("grep -q -- '--notify-self' /tmp/send-log.txt")
    machine.succeed("grep -q -- '-g XS8KGw==' /tmp/send-log.txt")
    machine.wait_until_succeeds("grep -q 'From Alice:' /tmp/send-log.txt")
    machine.wait_until_succeeds("grep -q 'From Alice in Friends:' /tmp/send-log.txt")
    machine.wait_until_succeeds("grep -q 'From Alice in Home:' /tmp/send-log.txt")
    machine.wait_until_succeeds("test $(grep -c 'hallo welt' /tmp/send-log.txt) -eq 7")
    machine.succeed("grep -q 'limit is 5 per hour' /tmp/send-log.txt")
    machine.succeed("test $(grep -c 'limit is 5 per hour' /tmp/send-log.txt) -eq 1")
    machine.succeed("grep -q 'no longer than 120 seconds' /tmp/send-log.txt")
    machine.wait_until_succeeds("test $(grep -c '^CALL:' /tmp/send-log.txt) -eq 9", timeout=30)

    # Single-object and newline-delimited JSON receive output are accepted;
    # typing events are ignored rather than reported as parse failures.
    machine.wait_until_succeeds("test -f /tmp/single-object-done", timeout=30)
    machine.wait_until_succeeds("test -f /tmp/ndjson-done", timeout=30)
    machine.sleep(1)
    machine.succeed("! journalctl -u signal-whisper --no-pager | grep -q 'could not parse signal-cli receive output'")

    # the service logged the transcription and the credentials were loaded
    machine.succeed("journalctl -u signal-whisper --no-pager | grep -q 'transcribing voice note'")
    machine.succeed("! journalctl -u signal-whisper --no-pager | grep -q 'getting msg'")
    machine.succeed("find /run/credentials -maxdepth 2 -name accounts.json | grep -q .")
    machine.succeed("find /run/credentials -maxdepth 2 -name config.json | grep -q .")
    machine.succeed("find /run/credentials -maxdepth 2 -name account | grep -q .")

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
