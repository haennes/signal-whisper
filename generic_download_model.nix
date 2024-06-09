{pkgs, model, hash, ...}:
let
warn = pkgs.writeShellScriptBin "donotrun" "echo do not run this";
in pkgs.stdenv.mkDerivation {
          name = model;
          src = pkgs.fetchurl {
            #curlOpts = "-L";
            url =
              "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${model}.bin";
            inherit hash;
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
