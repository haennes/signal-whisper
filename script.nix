{pkgs, out_path, model, name, ...}:
  pkgs.writeShellScriptBin name
        ''
           IFS=$'\n\t'
           path=$HOME
           files=$(ls $path -1 | grep -E '^(signal|Sprachnachricht).*(m4a|mp3|aac)$')
           echo $files
           for file in $files; do
             ffmpeg -i "$path/$file" -y -ar 16000 /tmp/out.wav -v 24 -stats
             whisper-cpp /tmp/out.wav -otxt -of "$path/$file" -l de -m  ${out_path}/${model} --print-progress
             mv  "$path/$file" "$path/processed_$file"
           done
             ''
