{pkgs, out_path, model, name, ...}:
  pkgs.writeShellScriptBin name
        ''
           ffmpeg -i ~/signal-*.mp3 -y -ar 16000 /tmp/out.wav -v 24 -stats
           whisper-cpp /tmp/out.wav -otxt -l de -m  ${out_path}/${model} --print-progress''
