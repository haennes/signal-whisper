{pkgs, name, model_name, model_pkg}:
let
      buildInputsPkgs = with pkgs; [ ffmpeg openai-whisper-cpp ];
      script = model: out_path: import ./script.nix {inherit pkgs out_path model; name = "${name}-${model}";};
in
pkgs.symlinkJoin {
          name = "${name}-${model_name}.bin";
          version = "0.0.1";
          paths =
            [ (script "${model_name}.bin" "${model_pkg}") model_pkg ]
            ++ buildInputsPkgs;
          buildInputs = with pkgs; [ makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/${name}-${model_name}.bin --prefix PATH : $out/bin --prefix PATH : ${model_pkg}/${model_name}.bin
          '';
        }
