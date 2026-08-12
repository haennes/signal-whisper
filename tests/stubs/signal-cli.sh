#!/usr/bin/env bash
# Test stub for signal-cli (only used by the NixOS VM test).
# Mimics the JSON layouts of signal-cli 0.13/0.14 for a linked device.
ACCT=""
DATA=""
ARGS=()
ORIG="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -a) ACCT="$2"; shift 2 ;;
    -d) DATA="$2"; shift 2 ;;
    -o|--output) shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
SUB="${ARGS[0]:-}"
case "$SUB" in
  receive)
    if [ ! -e /tmp/receive-done ]; then
      touch /tmp/receive-done
      printf 'notreallyaudiodata' > /tmp/voice-a.mp4
      printf 'notreallyaudiodata' > /tmp/voice-b.mp4
      cat <<'JSON'
[
  {
    "envelope": {
      "source": "+491234567890",
      "syncMessage": {
        "sentMessage": {
          "destination": "XS8KGw==",
          "attachments": [
            {"voiceNote": true, "contentType": "audio/mp4", "filename": "/tmp/voice-a.mp4"}
          ]
        }
      }
    }
  },
  {
    "envelope": {
      "source": "+491234567890",
      "dataMessage": {
        "groupInfo": {"groupId": "XS8KGw=="},
        "body": "plain text",
        "attachments": []
      }
    }
  },
  {
    "envelope": {
      "source": "+49876543210",
      "dataMessage": {
        "groupInfo": {"groupId": "XS8KGw=="},
        "attachments": [
          {"voiceNote": true, "contentType": "audio/mp4", "filename": "/tmp/voice-b.mp4"}
        ]
      }
    }
  }
]
JSON
    else
      printf '[]\n'
    fi
    ;;
  send)
    echo "CALL: $ORIG" >> /tmp/send-log.txt
    cat >> /tmp/send-log.txt
    ;;
  link)
    mkdir -p "$DATA/data/${ACCT}"
    printf '[{"path":"%s","environment":"live","number":"%s","uuid":"aaaaaaaa-0000-0000-0000-000000000001"}]\n' "$ACCT" "$ACCT" > "$DATA/data/accounts.json"
    echo "QRCODE-please-scan"
    ;;
  listAccounts)
    echo "$ACCT"
    ;;
esac
