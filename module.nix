{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.signal-whisper;
  name = "signal-whisper";

  modelPackages = import ./modelPackages.nix {
    inherit pkgs lib name;
  };
  modelPackage =
    if cfg.modelName == null then
      null
    else
      let
        packageName = lib.replaceStrings [ "." ] [ "_" ] cfg.modelName;
      in
      if builtins.hasAttr packageName modelPackages && !(lib.hasPrefix "${name}-" packageName) then
        modelPackages.${packageName}
      else
        null;
  modelPath =
    if cfg.model != null then
      cfg.model
    else if modelPackage != null then
      "${modelPackage}/${modelPackage.name}.bin"
    else
      "";

  secretsProvided =
    cfg.secrets.accountsFile != null
    || cfg.secrets.accountDbFile != null
    || cfg.secrets.accountFile != null
    || cfg.secrets.configFile != null;

  # Configuration is passed via environment variables set in the unit (not
  # baked into the script) so values with quotes/special chars are safe.
  script =
    pkgs.writers.writeNuBin "signal-whisper"
      {
        makeWrapperArgs = [
          "--prefix"
          "PATH"
          ":"
          "${lib.makeBinPath [
            pkgs.coreutils
            pkgs.ffmpeg
            cfg.signalCliPackage
            cfg.whisperPackage
          ]}"
        ];
      }
      ''
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

        def matches-group [id: string, ghex: string, gb64: string] {
          print $"matches group ($id) ($ghex) ($gb64)"
          if ($id | is-empty) { return false }
          let idl = ($id | str lowercase)
          ($idl == ($ghex | str lowercase)) or ($idl == ($gb64 | str lowercase))
        }

        def group-name [id: string, groups: list] {
          let idb64 = if ($id =~ "^[0-9a-fA-F]+$") {
            (try { $id | decode hex | encode base64 } catch { "" })
          } else { $id }
          let matches = ($groups | where { |g|
            (($g.id? | default "") | str lowercase) == ($idb64 | str lowercase)
          })
          if ($matches | is-empty) { "" } else { ($matches.0.name? | default "" | str trim) }
        }

        def record-messages [value: any] {
          if ($value | describe | str starts-with "record") {
            [$value]
          } else if (($value | describe | str starts-with "list") or ($value | describe | str starts-with "table")) {
            ($value | where { |item| $item | describe | str starts-with "record" })
          } else {
            []
          }
        }

        def parse-receive-output [stdout: string] {
          let parsed = (try { $stdout | from json } catch { null })
          if $parsed != null {
            (record-messages $parsed)
          } else {
            let messages = ($stdout
              | lines
              | each { |line| try { $line | from json } catch { null } }
              | where { |item| ($item != null) and ($item | describe | str starts-with "record") })
            if ($messages | is-empty) { null } else { $messages }
          }
        }

        def notify-group [cfg: record, body: string] {
          mut sargs = [send "-g" $cfg.group_b64]
          if $cfg.notify_self {
            $sargs = ($sargs | append "--notify-self")
          }
          let r = ($body | ^signal-cli -a $cfg.account ...$sargs --message-from-stdin | complete)
          if $r.exit_code != 0 {
            print -e $"signal-whisper: failed to notify selected group: ($r.stderr)"
          }
        }

        def notify-block [cfg: record, sender: string, body: string] {
          let now = (date now | into int)
          let entries = if ($cfg.rate_file | path exists) {
            (try { open --raw $cfg.rate_file | from json } catch { [] })
          } else { [] }
          let recent = ($entries | where { |e| ($now - $e.time) < 3600000000000 })
          let already_notified = ($recent | any { |e| ($e.sender == $sender) and ($e.notice? | default false) })
          if $already_notified { return }
          let updated = ($recent | append { sender: $sender, time: $now, notice: true })
          let tmp = ($cfg.rate_file + ".tmp")
          $updated | to json | save --force $tmp
          chmod 600 $tmp
          mv $tmp $cfg.rate_file
          notify-group $cfg $body
        }

        def consume-slot [sender: string, cfg: record] {
          let now = (date now | into int)
          let entries = if ($cfg.rate_file | path exists) {
            (try { open --raw $cfg.rate_file | from json } catch { [] })
          } else { [] }
          let recent = ($entries | where { |e| ($now - $e.time) < 3600000000000 })
          let sender_entries = ($recent | where { |e| ($e.sender == $sender) and not ($e.notice? | default false) })
          if ($sender_entries | length) >= 5 {
            return false
          }
          let updated = ($recent | append { sender: $sender, time: $now })
          let tmp = ($cfg.rate_file + ".tmp")
          $updated | to json | save --force $tmp
          chmod 600 $tmp
          mv $tmp $cfg.rate_file
          true
        }

        def process-msg [parsed: record, cfg: record] {
          let source = ($parsed.envelope?.source? | default "")
          let data = (get-data $parsed)
          if $data == null { return }
          let group = ($data.destination? | default ($data.groupInfo?.groupId? | default ""))
          print $"group ($group)"
          let bypass_limits = (matches-group $group $cfg.group_hex $cfg.group_b64)

          let atts = ($data.attachments?
            | default []
            | where { |a| ($a.voiceNote? == true) or (($a.contentType? | default "") | str starts-with "audio/") }
            | each { |a|
                let filename = ($a.filename? | default "")
                if not ($filename | is-empty) and ($filename | path exists) {
                  $filename
                } else {
                  let id = ($a.id? | default "")
                  if ($id | is-empty) { $filename } else { $"($env.HOME)/.local/share/signal-cli/attachments/($id)" }
                }
              }
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
            if not $bypass_limits {
              let probe = (^ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $att | complete)
              let duration = (try { $probe.stdout | str trim | into float } catch { null })
              if ($probe.exit_code != 0) or ($duration == null) {
                notify-block $cfg $source $"Blocked voice message from ($source): audio duration could not be verified."
                continue
              }
              if $duration > $cfg.max_audio_seconds {
                notify-block $cfg $source $"Blocked voice message from ($source): audio must be no longer than ($cfg.max_audio_seconds) seconds."
                continue
              }
              if not (consume-slot $source $cfg) {
                notify-block $cfg $source $"Blocked voice message from ($source): transcription limit is 5 per hour."
                continue
              }
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

          let source_name = ($parsed.envelope?.sourceName? | default "")
          let source_label = if ($source_name | is-empty) { $source } else { $source_name }
          let source_group = (group-name $group $cfg.groups)
          let origin = if ($source_group | is-empty) { $"From ($source_label)" } else { $"From ($source_label) in ($source_group)" }
          let header = if ($cfg.prefix | is-empty) {
            $origin
          } else if ($cfg.prefix | str ends-with " ") {
            $"($cfg.prefix)($origin)"
          } else {
            $"($cfg.prefix) ($origin)"
          }
          let body = $"($header):\n($reply)"
          print -e $"signal-whisper: transcribing voice note from ($source) in ($group)"
          notify-group $cfg $body
        }

        def main [] {
          # Secrets (account and group id) come from config.json loaded via
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
            prefix: ($env.SIGNAL_WHISPER_PREFIX | default "")
            notify_self: (($env.SIGNAL_WHISPER_NOTIFY_SELF | default "1") == "1")
            max_audio_seconds: (($env.SIGNAL_WHISPER_MAX_AUDIO_SECONDS | default "120") | into int)
            rate_file: ($env.HOME | path join ".signal-whisper-rate-limits.json")
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

          let groups_out = (^signal-cli -a $cfg.account -o json listGroups | complete)
          let groups = if $groups_out.exit_code == 0 {
            (try { $groups_out.stdout | from json } catch { [] })
          } else { [] }
          let cfg = { ...$cfg groups: $groups }

          print -e $"signal-whisper: starting receive loop \(account=($cfg.account), group=($cfg.send_group)\)"
          loop {
            let out = (^signal-cli -a $cfg.account -o json receive -t 5 | complete)
            if $out.exit_code != 0 {
              print -e $"signal-whisper: signal-cli receive failed: ($out.stderr)"
              sleep 10sec
              continue
            }
            let stdout = ($out.stdout | str trim)
            if ($stdout | is-empty) {
              sleep 10sec
              continue
            }
            let parsed = (parse-receive-output $stdout)
            if ($parsed == null) {
              print -e "signal-whisper: could not parse signal-cli receive output"
              sleep 10sec
              continue
            }
            for m in $parsed {
              process-msg $m $cfg
            }
            sleep 10sec
          }
        }
      '';

  installSecrets =
    pkgs.writers.writeNuBin "signal-whisper-install-secrets"
      {
        makeWrapperArgs = [
          "--prefix"
          "PATH"
          ":"
          "${lib.makeBinPath [ pkgs.coreutils ]}"
        ];
      }
      ''
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

          let marker = ($home | path join ".signal-whisper-secrets-installed")
          if ($marker | path exists) {
            print "signal-whisper: account secrets already installed, skipping"
            return
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

          touch $marker
          print $"signal-whisper: installed account secrets for ($account)"
        }
      '';
in
{
  options.services.signal-whisper = {
    enable = lib.mkEnableOption ''
      a systemd service that receives Signal messages and transcribes voice
      notes from any sender using whisper, then sends the transcription to a
      dedicated group.

      signal-cli is registered as an additional (linked) device of your
      phone number. Link it once on a trusted machine (your phone is needed
      to scan the QR code):

        nix run .#signal-whisper-link -- <phone number> <out-dir>

      The linking script exports the secret files (including a config.json
      holding the account and selected group) that must
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

    group = lib.mkOption {
      type = lib.types.str;
      default = "signal-whisper";
      description = "System group the service runs as.";
    };

    model = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "\"\${pkgs.large-v3-q5_0}/large-v3-q5_0.bin\"";
      description = ''
        Path to a ggml-*.bin whisper model.
      '';
    };

    modelName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "tiny.en";
      description = ''
        Name of a model packaged by this flake.
        For a list of all models see `modelPackages.nix` in the repo.

        To use a model not packaged in this flake, use `service.signal-whisper.model`.
      '';
    };

    whisperPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.whisper-cpp;
      defaultText = "pkgs.whisper-cpp";
      description = "whisper.cpp binary to use for transcription.";
    };

    signalCliPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.signal-cli;
      defaultText = "pkgs.signal-cli";
      description = "signal-cli binary to use for the Signal receive/send loop.";
    };

    language = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      example = "de";
      description = "Language to pass to whisper ('auto' lets it guess).";
    };

    messagePrefix = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Optional text prepended to the sender and group header.";
    };

    notifySelf = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Send the transcription with --notify-self so it also shows up in the
        conversation on the phone.
      '';
    };

    maxAudioLengthSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Reject voice messages longer than this many seconds outside the selected group.";
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
          This files user and group must match signal-whisper's.
          All other secrets may be owned by any user and group.
          Usually wired to agenix/sops via a file path.
        '';
      };
      configFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Secret file `config.json` as exported by the linking script. It
          holds the account (phone number) and selected group id, e.g.:
          {"account": "+491234567890", "groupId": "5d2f..."}.
          Voice messages from any sender are accepted; legacy `senders` fields
          in existing config files are ignored.
          Usually wired to agenix/sops via a file path.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.modelName != null || cfg.model != null;
        message = "Either `services.signal-whisper.modelName` or `services.signal-whisper.model` must be set.";
      }
      {
        assertion = cfg.modelName == null || cfg.model == null;
        message = "Only one of `services.signal-whisper.modelName` or `services.signal-whisper.model` may be set.";
      }
      {
        assertion =
          cfg.modelName == null
          || modelPackage != null;
        message = "`services.signal-whisper.modelName` must name a model package provided by this flake.";
      }
      {
        assertion =
          !secretsProvided
          || (
            cfg.secrets.accountsFile != null
            && cfg.secrets.accountDbFile != null
            && cfg.secrets.configFile != null
            && cfg.secrets.accountFile != null
          );
        message = ''
          services.signal-whisper.secrets.accountFile,
          services.signal-whisper.secrets.accountsFile,
          services.signal-whisper.secrets.accountDbFile and
          services.signal-whisper.secrets.configFile must be set together.
        '';
      }
    ];

    warnings = lib.mkIf (!secretsProvided) [
      ''
        services.signal-whisper is enabled but no account secrets were
        configured. Link the device on a trusted machine:

          nix run .#signal-whisper-link -- <phone number> <out-dir>

        and supply the three files it exports to this server:

          services.signal-whisper.secrets.accountsFile = "/path/to/accounts.json";
          services.signal-whisper.secrets.accountFile = "/path/to/account";
          services.signal-whisper.secrets.accountDbFile = "/path/to/account.db";
          services.signal-whisper.secrets.configFile = "/path/to/config.json";
      ''
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
      description = "Signal voice note transcription service";
    };
    users.groups.${cfg.group} = { };

    systemd.services.signal-whisper = {
      description = "Signal voice note transcription";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      preStart = lib.mkIf secretsProvided "${installSecrets}/bin/signal-whisper-install-secrets";
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = 15;
        Environment = [
          "HOME=${cfg.dataDir}"
          "SIGNAL_WHISPER_MODEL=${modelPath}"
          "SIGNAL_WHISPER_LANGUAGE=${cfg.language}"
          "SIGNAL_WHISPER_PREFIX=${cfg.messagePrefix}"
          "SIGNAL_WHISPER_NOTIFY_SELF=${if cfg.notifySelf then "1" else "0"}"
          "SIGNAL_WHISPER_MAX_AUDIO_SECONDS=${toString cfg.maxAudioLengthSeconds}"
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
