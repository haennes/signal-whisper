{
  description = "using whisper to translate signal speech notes saved in ~";

  inputs = { nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable"; };

  outputs = { nixpkgs, systems, self, ... }:
    let
      eachSystem = f: nixpkgs.lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system} nixpkgs.lib);
      models = [
        ["tiny.en" "sha256-kh5M+Ghv3Zk9zQgaXaW2w2W/3hFi5ysI11rHUomSCx8="]
        ["tiny" "sha256-vgfgSOHlma1GNByNKhNWRQl6U4IhZ4t6zdGxkZxuGyE="]
        ["tiny-q5_1" "sha256-gYcQVo2jyhVonjGnQxl7UgAHhy/5V2I3val70bRpw9c="]
        ["tiny.en-q5_1" "sha256-x3xXZvHO8JtrfUfyG1Rsvd1BV4hrO11tT3CekeZsfCs="]
        ["tiny.en-q8_0" "sha256-W8KzhgqhUaTG57sJXh/M588Sx7Agygjc7AxtAYu33ZQ="]
        ["base.en" "sha256-oDd5yG3zMjB19eeWyyzlAp8A7Ihp7uP9+4l6/jbG0AI="]
        ["base" "sha256-YO1bw90U7qhWST0zQ0m0BXgt3K8AKNS130CINF+6Lv4="]
        ["base-q5_1" "sha256-Qi8a5FKt5vMKAE1+XGpDGV5EM7w3C/I/rJzFkfAaiJg="]
        ["base.en-q5_1" "sha256-S69w3Q18Qke6K4H6/ZwBAFrHfC+e8GTgDc8ZXQ4v3S8="]
        ["small.en" "sha256-xhONbVjsyDIgl+D5h8MvG+i7ChhTKj+I9zTRu/nEHl0="]
        ["small" "sha256-G+OpsgY4Z7k35k4ux0gzZKeZF+FX+pjF2UtcH//qmHs="]
        ["small-q5_1" "sha256-roXkqTXXpWe9EC/lWvwWu1lb22GOEbL8dZG8CBIEEbs="]
        ["small.en-q5_1" "sha256-v9/0iU3Ldrv2R9ViY+oqlmRUI/FmkXb0hEob+OR4rTA="]
        ["medium" "sha256-bBTVre5fhjlAN7Tk6LWfFnO2zuEOPPCxG72+55wVYgg="]
        ["medium.en" "sha256-zDfpNHgzjsdwAoGnrDChASiSnrj0J92i6GX6qPbaQ1Y="]
        ["medium-q5_0" "sha256-Gf6ks4DDphjsRyPD7vLreF/7oNBTjPQ/jyNeezs0Ig8="]
        ["medium.en-q5_0" "sha256-dnM+Jq2P4celv3UxqdQZF7KtwPIPLk9VMWiKjGzYjrA="]
        ["large-v1" "sha256-fZn0GhBSXQIGvdrdhnYBgfqSBDi2szI34xGP9sg7tT0="]
        ["large-v2" "sha256-mkI/5NQMgndLavNBFbi5NfNBUiRusZ6A43YHHT+ZlIc="]
        ["large-v2-q5_0" "sha256-OiFINyIeRTDbwf6Nc08wKvOT6zC9DtBGBC6/S69w9vI="]
        ["large-v3" "sha256-ZNGCtEC5jVIDxPm9VBVE2ExgUZbE97hF36EfsjWU0eI="]
        ["large-v3-q5_0" "sha256-11eV7P8/g7X6qJ0ZAGBK2MeAq9Vzn65AbeGfI+zZitE="]
      ];
      name = "signal-whisper";


    in {
      packages = eachSystem (pkgs: lib:
      let
      recursiveMerge = listOfAttrsets:
        lib.fold (attrset: acc: lib.recursiveUpdate attrset acc) { }
        listOfAttrsets;
      generic_model_download = model: hash:
        import ./generic_download_model.nix { inherit pkgs model hash; };
      generic_whisper = model_name: model_pkg:
        import ./generic_whisper.nix {
          inherit pkgs model_name model_pkg name;
        };
      in
        recursiveMerge (lib.lists.map (model:
      let
      model_name = lib.lists.head model;
      model_hash = lib.lists.last model;
      safe_model_name = lib.replaceStrings ["."]["_"] model_name;
      curr = generic_model_download model_name model_hash;
      in
      {
        "${safe_model_name}" = curr;

        "signal-whisper-${safe_model_name}" = generic_whisper model_name curr;
      }) models)
      );
      overlays.default = final: prev:
        let system = prev.stdenv.hostPlatform.system;
        in self.packages."${system}";
    };
}
