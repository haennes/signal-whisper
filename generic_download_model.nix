{pkgs, model, ...}:
let
warn = pkgs.writeShellScriptBin "donotrun" "echo do not run this";
in pkgs.stdenv.mkDerivation {
          name = model;
          src = pkgs.fetchurl {
            #curlOpts = "-L";
            url =
              "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${model}.bin";
            hash = "sha256-11eV7P8/g7X6qJ0ZAGBK2MeAq9Vzn65AbeGfI+zZitE=";
          };
          phases = [ "installPhase" "unpackPhase" ];
          installPhase = ''
            mkdir -p $out/bin
            cp ${warn}/bin/donotrun $out/bin/${model}
          '';
          unpackPhase = ''
            cp $src $out/${model}.bin
          '';
}
