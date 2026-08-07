{ config, lib, pkgs, ... }:

let
  cfg = config.services.signal-whisper;

  secretsProvided =
    cfg.secrets.accountsFile != null || cfg.secrets.accountDbFile != null
    || cfg.secrets.configFile != null;

  # Configuration is passed via environment variables set in the unit (not
  # baked into the script) so values with quotes/special chars are safe.
  script = pkgs.writers.writeNuBin "signal-whisper" {
    makeWrapperArgs = [
      "--prefix" "PATH" ":"
      "${lib.makeBinPath [
        pkgs.coreutils
        pkgs.ffmpeg
        pkgs.signal-cli
        cfg.whisperPackage
      ]}"
    ];
  } ''
    def get-data [parsed: record] {
      # On a linked device, messages the phone itself sent come in as sync
      # messages; messages from other group members come in as data messages.
      if ($parsed.envelope?.syncMessage?.sentMessage?) != null {
        $parsed.envelope.syncMessage.sentMessage
      } else if ($parsed.envelope?.dataMessage?) != null {
        $parsed.envelope.dataMessage
      } else {
        null
      }
    }

    def allowed-sender [s: string, account: string, senders: list<string>] {
      if ($s | is-empty) { return false }
      if $s == $account { return true }
      print $"($s) in ($senders)"
      $s in $senders
    }

    def matches-group [id: string, ghex: string, gb64: string] {
      print $"matches group ($id) ($ghex) ($gb64)"
      if ($id | is-empty) { return false }
      let idl = ($id | str lowercase)
      ($idl == ($ghex | str lowercase)) or ($idl == ($gb64 | str lowercase))
    }

    def process-msg [parsed: record, cfg: record] {
      print $"processing message: ($parsed)"
      let source = ($parsed.envelope?.source? | default "")
      let data = (get-data $parsed)
      if $data == null { return }
      let group = ($data.destination? | default ($data.groupInfo?.groupId? | default ""))
      print $"group ($group)"
      if not (matches-group $group $cfg.group_hex $cfg.group_b64) {
        print "does not match group skipping"
        return
      }
      if not (allowed-sender $source $cfg.account $cfg.senders) {
        print $"sender ($source) not allowed"
        return
      }

      let atts = ($data.attachments?
        | default []
        | where { |a| ($a.voiceNote? == true) or (($a.contentType? | default "") | str starts-with "audio/") }
        | each { |a| $a.filename? | default $"($env.HOME)/.local/share/signal-cli/attachments/($a.id)" }
        | where { |f| $f != null })
      if ($atts | is-empty) {
        print $"no audio attachment in ($data.attachments?)"
        return
      }

      let tmpdir = (mktemp -d)
      mut reply = ""
      for att in $atts {
        print $"processing audio attachment ($att)"
        if not ($att | path exists) {
          print "attachment path does not exist"
          continue
        }
        let wav = ($tmpdir | path join "in.wav")
        let out = ($tmpdir | path join "out")
        let f = (^ffmpeg -y -v error -i $att -ar 16000 -ac 1 -f wav $wav | complete)
        if $f.exit_code != 0 {
          print $"ffmpeg failed ffmpeg -y -v error -i ($att) -ar 16000 -ac 1 -f wav ($wav)"
          continue
        }
        mut wargs = [-m $cfg.model -f $wav -otxt -of $out]
        if $cfg.language != "auto" {
          $wargs = ($wargs | append "-l")
          $wargs = ($wargs | append $cfg.language)
        }
        print $"whisper started with ($wargs)"
        let w = (^whisper-cli ...$wargs | complete)
        if $w.exit_code != 0 {
          print "whisper failed"
          continue
        }
        let text = (try { open --raw ($out + ".txt") } catch { "" })
        $reply += $text
      }
      rm -rf $tmpdir
      if ($reply | is-empty) { return }

      print -e $"signal-whisper: transcribing voice note from ($source) in group ($cfg.group_b64)"
      mut sargs = [send "-g" $cfg.group_b64]
      if $cfg.notify_self {
        $sargs = ($sargs | append "--notify-self")
      }
      let body = $"($cfg.prefix)($reply)"
      let r = ($body | ^signal-cli -a $cfg.account ...$sargs --message-from-stdin | complete)
      if $r.exit_code != 0 {
        print -e "signal-whisper: failed to send transcription"
        print $"signal-cli -a ($cfg.account) ($sargs) ($body)"
      }
    }

    def main [] {
      # Secrets (account, group id, senders) come from config.json loaded via
      # LoadCredential; the env vars are only a fallback for manual runs.
      let creds = ($env.CREDENTIALS_DIRECTORY? | default "")
      let conf = if ($creds | is-empty) {
        null
      } else {
        let p = ($creds | path join "config.json")
        if ($p | path exists) {
          (try { open --raw $p | from json } catch { null })
        } else {
          null
        }
      }

      let cfg = {
        account: (if $conf != null { $conf.account? | default "" } else { $env.SIGNAL_WHISPER_ACCOUNT? | default "" })
        model: ($env.SIGNAL_WHISPER_MODEL | default "")
        language: ($env.SIGNAL_WHISPER_LANGUAGE | default "auto")
        prefix: ($env.SIGNAL_WHISPER_PREFIX | default "Transcript: ")
        notify_self: (($env.SIGNAL_WHISPER_NOTIFY_SELF | default "1") == "1")
      }

      # Normalize the configured group id so we can match it regardless of
      # whether signal-cli reports it as hex or base64.
      let group_raw = (if $conf != null { $conf.groupId? | default "" } else { $env.SIGNAL_WHISPER_GROUP_ID? | default "" })
      let cfg = if ($group_raw | is-empty) {
        $cfg
      } else if ($group_raw =~ "^[0-9a-fA-F]+$") {
        { ...$cfg
          group_hex: $group_raw
          group_b64: (try { $group_raw | decode hex | encode base64 } catch { "" })
          send_group: $group_raw
        }
      } else {
        let hex = (try { $group_raw | decode base64 | into binary | encode hex | str lowercase } catch { "" })
        { ...$cfg
          group_hex: $hex
          group_b64: $group_raw
          send_group: (if ($hex | is-empty) { $group_raw } else { $hex })
        }
      }

      let senders = if $conf != null {
        ($conf.senders? | default [])
      } else {
        let raw = ($env.SIGNAL_WHISPER_SENDERS? | default "")
        if ($raw | is-empty) { [] } else { ($raw | split row "," | where { |s| not ($s | is-empty) }) }
      }
      let cfg = { ...$cfg senders: $senders }

      print -e $"signal-whisper: starting receive loop \(account=($cfg.account), group=($cfg.send_group)\)"
      loop {
        print "getting msg"
        let raw = ((^signal-cli -a $cfg.account -o json receive -t 5) | lines)
        if ($raw | length ) == 0 {
          sleep 10sec
          continue
        }
        let parsed = ($raw | reduce {|e, acc| $acc + "," + $e} | "[" + $in +  "]" | from json)
        print $"recieved msg ($raw) ($parsed)"
        for m in $parsed {
          print $"processing message ($m)"
          process-msg $m $cfg
        }
        sleep 10sec
      }
    }
  '';

  installSecrets = pkgs.writers.writeNuBin "signal-whisper-install-secrets" {
    makeWrapperArgs = [
      "--prefix" "PATH" ":" "${lib.makeBinPath [ pkgs.coreutils ]}"
    ];
  } ''
    def find-account [value: any, account: string] {
      if ($value | describe | str starts-with "record") {
        if (($value.number? | default "") == $account) or (($value.uuid? | default "") == $account) {
          return ($value.path? | default "")
        }
        for k in ($value | columns) {
          let r = (find-account ($value | get $k) $account)
          if not ($r | is-empty) { return $r }
        }
        ""
      } else if ($value | describe | str starts-with "list") or ($value | describe | str starts-with "table") {
        for item in $value {
          let r = (find-account $item $account)
          if not ($r | is-empty) { return $r }
        }
        ""
      } else {
        ""
      }
    }

    def main [] {
      print "starting secret install"
      let home = ($env.HOME | default "")
      let creds = ($env.CREDENTIALS_DIRECTORY | default "")
      if ($home | is-empty) or ($creds | is-empty) {
        print -e "signal-whisper: HOME and CREDENTIALS_DIRECTORY must be set"
        exit 1
      }

      let conf = (try { open --raw ($creds | path join "config.json") | from json } catch { null })
      let account = (if $conf == null { $env.SIGNAL_WHISPER_ACCOUNT? | default "" } else { $conf.account? | default "" })
      if ($account | is-empty) {
        print -e "signal-whisper: account not found in secrets config.json"
        exit 1
      }

      let data_dir = ($home | path join ".local/share/signal-cli/data")
      mkdir $data_dir
      install -m 600 ($creds | path join "accounts.json") ($data_dir | path join "accounts.json")

      let accts = (try { open --raw ($data_dir | path join "accounts.json") | from json } catch { null })
      let acct = if $accts == null { "" } else { (find-account $accts $account) }
      if ($acct | is-empty) {
        print -e $"signal-whisper: could not resolve the account directory for ($account) in accounts.json"
        exit 1
      }

      let acct_dir = ($data_dir | path join $"($acct).d")
      mkdir $acct_dir
      let db = ($env.SIGNAL_WHISPER_ACCOUNT_DB_FILE | default "")
      if ($db | is-empty) {
        print -e "signal-whisper: SIGNAL_WHISPER_ACCOUNT_DB_FILE not set"
        exit 1
      }

      install -m 600 $db ($acct_dir | path join "account.db")

      let acct_file = ($data_dir | path join $acct)
      install -m 600 ($creds | path join "account") $acct_file

      print $"signal-whisper: installed account secrets for ($account)"
    }
  '';
in
{
  options.services.signal-whisper = {
    enable = lib.mkEnableOption ''
      a systemd service that receives Signal messages and transcribes voice
      notes sent by you to a dedicated group using whisper.

      signal-cli is registered as an additional (linked) device of your
      phone number. Link it once on a trusted machine (your phone is needed
      to scan the QR code):

        nix run .#signal-whisper-link -- <phone number> <out-dir>

      The linking script exports the secret files (including a config.json
      holding the account, the group id and the allowed senders) that must
      then be supplied to the server via `secrets.accountsFile`,
      `secrets.accountDbFile` and `secrets.configFile`.
    '';

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/signal-whisper";
      description = "Directory that holds the signal-whisper and signal-cli data.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "signal-whisper";
      description = "System user the service runs as.";
    };

    model = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a ggml-*.bin whisper model, e.g. one of the
        signal-whisper-* model packages built by this flake.
      '';
    };

    whisperPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.whisper-cpp;
      defaultText = "pkgs.whisper-cpp";
      description = "whisper.cpp binary to use for transcription.";
    };

    language = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      example = "de";
      description = "Language to pass to whisper ('auto' lets it guess).";
    };

    messagePrefix = lib.mkOption {
      type = lib.types.str;
      default = "Transcript: ";
      description = "Text prepended to each transcription sent to the group.";
    };

    notifySelf = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Send the transcription with --notify-self so it also shows up in the
        conversation on the phone.
      '';
    };

    secrets = {
      accountsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Secret file `accounts.json` as exported by the linking script.
          Usually wired to agenix/sops via a file path.
        '';
      };
      accountFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Secret file `account` as exported by the linking script.
          Usually wired to agenix/sops via a file path.
        '';
      };
      accountDbFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Secret file `account.db` as exported by the linking script.
          Usually wired to agenix/sops via a file path.
        '';
      };
      configFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Secret file `config.json` as exported by the linking script. It
          holds the account (phone number), the id of the group to watch and
          the optional list of allowed senders, e.g.:
          {"account": "+491234567890", "groupId": "5d2f...", "senders": []}.
          `senders` may contain phone numbers allowed to trigger
          transcription; by default only the account's own number is allowed.
          Usually wired to agenix/sops via a file path.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [ {
      assertion = !secretsProvided
        || (cfg.secrets.accountsFile != null && cfg.secrets.accountDbFile != null
            && cfg.secrets.configFile != null && cfg.secrets.accountFile != null);
      message = ''
        services.signal-whisper.secrets.accountsFile,
        services.signal-whisper.secrets.accountDbFile and
        services.signal-whisper.secrets.configFile must be set together.
      '';
    } ];

    warnings = lib.mkIf (!secretsProvided) [
      ''
        services.signal-whisper is enabled but no account secrets were
        configured. Link the device on a trusted machine:

          nix run .#signal-whisper-link -- <phone number> <out-dir>

        and supply the three files it exports to this server:

          services.signal-whisper.secrets.accountsFile = "/path/to/accounts.json";
          services.signal-whisper.secrets.accountDbFile = "/path/to/account.db";
          services.signal-whisper.secrets.configFile = "/path/to/config.json";
      ''
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.dataDir;
      createHome = true;
      description = "Signal voice note transcription service";
    };
    users.groups.${cfg.user} = { };

    systemd.services.signal-whisper = {
      description = "Signal voice note transcription";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      preStart = lib.mkIf secretsProvided
        "${installSecrets}/bin/signal-whisper-install-secrets";
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.user;
        Restart = "on-failure";
        RestartSec = 15;
        Environment = [
          "HOME=${cfg.dataDir}"
          "SIGNAL_WHISPER_MODEL=${cfg.model}"
          "SIGNAL_WHISPER_LANGUAGE=${cfg.language}"
          "SIGNAL_WHISPER_PREFIX=${cfg.messagePrefix}"
          "SIGNAL_WHISPER_NOTIFY_SELF=${if cfg.notifySelf then "1" else "0"}"
          "SIGNAL_WHISPER_ACCOUNT_DB_FILE=${cfg.secrets.accountDbFile}"

        ];
        WorkingDirectory = cfg.dataDir;
        LoadCredential = lib.mkIf secretsProvided [
          "accounts.json:${cfg.secrets.accountsFile}"
          "config.json:${cfg.secrets.configFile}"
          "account:${cfg.secrets.accountFile}"
        ];
        ExecStart = "${script}/bin/signal-whisper";
      };
    };
  };
}
