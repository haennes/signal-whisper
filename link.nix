{ pkgs, lib, name }:

# Links a new signal-cli device (paired with the user's phone) and exports
# the secret files needed to deploy `services.signal-whisper` to a server
# without having to do the linking there.
pkgs.writers.writeNuBin "signal-whisper-link" {
  makeWrapperArgs = [
      "--prefix" "PATH" ":"
      "${lib.makeBinPath [ pkgs.coreutils pkgs.signal-cli pkgs.qrencode pkgs.fzf ]}"
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

  def main [account: string, out?: string] {
    let out = if ($out | is-empty) { "./signal-whisper-secrets" } else { $out }
    let data_dir = ((mktemp -d) | path join "signal-cli")
    mkdir $data_dir

    print $"== linking ($account) \(isolated data dir: ($data_dir)\) =="
    print "Scan the QR code shown below with your phone:"
    print "  Signal -> Settings -> Linked devices -> Link new device"
    print ""
    # Stream stdout line by line: signal-cli prints the sgnl:// qr uri up front
    # and then blocks waiting for the phone, and nu would otherwise hold the
    # captured output until the command finishes (i.e. never, on success).
    # The uri is rendered as a QR code directly in the terminal.
    ^signal-cli -d $data_dir link -n "${name}" | lines | each { |l|
      if ($l | str starts-with "sgnl://") {
        print $l
        print ""
        print "QR code:"
        ^qrencode -t ANSIUTF8 $l | print
        print ""
      } else {
        print $l
      }
    }

    print "== verifying account =="
    ^signal-cli -d $data_dir listAccounts

    let accounts_json = ($data_dir | path join "data" "accounts.json")
    if not ($accounts_json | path exists) {
      print -e $"signal-whisper-link: ($accounts_json) not found"
      exit 1
    }


    let accts = (open --raw $accounts_json | from json)
    let acct = (find-account $accts $account)
    if ($acct | is-empty) {
      print -e $"signal-whisper-link: could not resolve the account directory for ($account) in accounts.json"
      exit 1
    }

    let account_json = ($data_dir | path join "data" $acct)
    if not ($account_json | path exists) {
      print -e $"signal-whisper-link: ($account_json) not found"
      exit 1
    }

    let account_db = ($data_dir | path join "data" $"($acct).d" "account.db")
    if not ($account_db | path exists) {
      print -e $"signal-whisper-link: ($account_db) not found"
      exit 1
    }

    print ""
    print "== choosing group to watch =="
    let groups = (try {
      ^signal-cli -a $account -d $data_dir -o json listGroups | from json
    } catch { [] })

    let group_lines = ($groups | each { |g|
      let gn = if (($g.name? | default "" | str trim) | is-empty) { $g.id } else { $g.name }
      $"($gn)\t($g.id)"
    })

    let entries = ([ "Create a new group...\t__create__" ] | append $group_lines)

    print "Pick a group (fuzzy search by name, or pick the first entry to create a new one):"
    let pick = (($entries | str join "\n") | ^fzf --delimiter "\t" --nth 1 --with-nth 1 --preview "echo {} | cut -f2")
    if ($pick | str trim | is-empty) {
      print -e "signal-whisper-link: no group selected"
      print -e $"  find the group id later with: signal-cli -a ($account) -d ($data_dir) -o json listGroups"
      print -e "  and set services.signal-whisper.groupId accordingly."
      exit 1
    }

    let sel = ($pick | str trim | split row "\t")
    let sel_name = ($sel | first)
    let sel_id = ($sel | last)

    let group = if $sel_id == "__create__" {
      let ans = (input --numchar 1 "No group selected. Create a new Signal group and watch it? [y/N] " | str lowercase)
      if $ans != "y" {
        print -e "signal-whisper-link: aborted, no group selected"
        exit 1
      }
      let gname = (input "Name of the new group: " | str trim)
      if ($gname | is-empty) {
        print -e "signal-whisper-link: no name given, aborted"
        exit 1
      }
      print $"== creating group '($gname)' =="
      let cr = (^signal-cli -a $account -d $data_dir updateGroup -n $gname | complete)
      if $cr.exit_code != 0 {
        print -e $"signal-whisper-link: failed to create group: ($cr.stderr)"
        exit 1
      }
      let parsed = (try { $cr.stdout | parse -r "(?i)group id[ :]+(?P<id>[0-9a-fA-F]+)" } catch { [] })
      let pid = if ($parsed | is-empty) { "" } else { $parsed.0.id }
      let cid = if not ($pid | is-empty) {
        $pid
      } else {
        let gs = (try { ^signal-cli -a $account -d $data_dir -o json listGroups | from json } catch { [] })
        let ms = ($gs | where { |g| ($g.name? | default "") == $gname })
        if ($ms | length) == 1 { $ms.0.id } else { "" }
      }
      if ($cid | is-empty) {
        print -e "signal-whisper-link: could not determine the id of the new group"
        print -e $"  output of the create command was:"
        print -e $cr.stdout
        print -e $"  find it with: signal-cli -a ($account) -d ($data_dir) -o json listGroups"
        exit 1
      }
      { name: $gname, id: $cid }
    } else {
      { name: $sel_name, id: $sel_id }
    }

    print $"== watching group '($group.name)' (($group.id)) =="

    mkdir $out
    install -m 600 $accounts_json ($out | path join "accounts.json")
    install -m 600 $account_db ($out | path join "account.db")
    install -m 600 $account_json ($out | path join "account")

    let config = {
      account: $account
      groupId: $group.id
      senders: []
    }
    let out_config = ($out | path join "config.json")
    let out_accounts = ($out | path join "accounts.json")
    let out_account = ($out | path join "account")
    let out_db = ($out | path join "account.db")
    $config | to json | save --force $out_config
    chmod 600 $out_config

    print ""
    print "================================================================"
    print " DONE. The following secret files must be supplied to the server:"
    print "================================================================"
    print $"  1) ($out_accounts)"
    print $"  2) ($out_db)"
    print $"  3) ($out_config)"
    print $"  4) ($out_account)"
    print ""
    print "On the server, configure the module with:"
    print "  services.signal-whisper.secrets.accountFile = /path/to/account;"
    print "  services.signal-whisper.secrets.accountsFile = /path/to/accounts.json;"
    print "  services.signal-whisper.secrets.accountDbFile = /path/to/account.db;"
    print "  services.signal-whisper.secrets.configFile = /path/to/config.json;"
    print ""
    print $"config.json watches group '($group.name)' (($group.id)) for sender ($account)."
    print "Add other allowed senders to the 'senders' list in config.json if needed."
  }
''
