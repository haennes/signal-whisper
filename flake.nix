{
  description = "A very basic flake";

  inputs = { nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable"; };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      name = "signal-whisper";
      script = out_path: pkgs.writeScriptBin name "
        #!/bin/sh
        ffmpeg -i ~/signal-*.mp3 -y -ar 16000 /tmp/out.wav -v 24 -stats
        whisper-cpp /tmp/out.wav -otxt -l de -m  ${out_path}/large-v3-q5_0.bin --print-progress
      ";
      buildInputsPkgs = with pkgs; [ ffmpeg openai-whisper-cpp ];
      warn = pkgs.writeShellScriptBin "donotrun" "echo do not run this";
    in {
      packages.x86_64-linux = rec {
        large-v3-q5_0 = pkgs.stdenv.mkDerivation {
          name = "large-v3-q5_0.bin";
          src = pkgs.fetchurl {
            #curlOpts = "-L";
            url =
              "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin";
            hash = "sha256-ZNGCtEC5jVIDxPm9VBVE2ExgUZbE97hF36EfsjWU0eI=";
          };
          phases = ["installPhase" "unpackPhase"];
          installPhase = ''
             mkdir -p $out/bin
             cp ${warn}/bin/donotrun $out/bin/large
          '';
          unpackPhase = ''
             cp $src $out/large-v3-q5_0.bin
          '';
        };

        default = signal-whisper;
        signal-whisper = pkgs.symlinkJoin {
          inherit name;
          version = "0.0.1";
          paths = [ (script "${large-v3-q5_0}")  large-v3-q5_0] ++ buildInputsPkgs;
          buildInputs = with pkgs; [ makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/${name} --prefix PATH : $out/bin --prefix PATH : ${large-v3-q5_0}/large-v3-q5_0.bin
          '';
        };
      };

    };
}
