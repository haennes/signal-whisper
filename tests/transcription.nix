# Transcription test with a real audio file.
#
# Unlike the VM test (which stubs out whisper-cpp), this check feeds a real
# mp3 recording through the actual pipeline used by the service: ffmpeg
# converts the attachment to a 16 kHz mono wav, whisper-cli transcribes it
# with a real model and the resulting text is checked.
{ pkgs }:

let
  model = import ../generic_download_model.nix {
    inherit pkgs;
    model = "tiny.en";
    hash = "sha256-kh5M+Ghv3Zk9zQgaXaW2w2W/3hFi5ysI11rHUomSCx8=";
  };
in
pkgs.runCommand "signal-whisper-transcription-test" {
  nativeBuildInputs = [ pkgs.ffmpeg pkgs.whisper-cpp ];
} ''
  ffmpeg -y -v error -i ${./transcribing.mp3} -ar 16000 -ac 1 -f wav in.wav
  whisper-cli -m ${model}/tiny.en.bin -f in.wav -otxt -of out

  test -s out.txt
  grep -qi 'dickinson' out.txt || {
    echo "unexpected transcription:"
    cat out.txt
    exit 1
  }

  echo "transcription test passed:"
  cat out.txt
  touch $out
''
