{
  description = "A very basic flake";

  inputs = { nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable"; };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      models = [
        "tiny.en"
        "tiny"
        "tiny-q5_1"
        "tiny.en-q5_1"
        "base.en"
        "base"
        "base-q5_1"
        "base.en-q5_1"
        "small.en"
        "small.en-tdrz"
        "small"
        "small-q5_1"
        "small.en-q5_1"
        "medium"
        "medium.en"
        "medium-q5_0"
        "medium.en-q5_0"
        "large-v1"
        "large-v2"
        "large-v3"
        "large-v3-q5_0"
      ];
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;
      name = "signal-whisper";
      recursiveMerge = listOfAttrsets:
        lib.fold (attrset: acc: lib.recursiveUpdate attrset acc) { }
        listOfAttrsets;
      generic_model_download = model: import ./generic_download_model.nix{inherit pkgs model;};
      generic_whisper = model_name: model_pkg: import ./generic_whisper.nix{inherit pkgs model_name model_pkg name;};

    in {
      packages.x86_64-linux = rec {
        large-v3-q5_0 = generic_model_download "large-v3-q5_0";

        default = signal-whisper;
        signal-whisper = generic_whisper "large-v3-q5_0" large-v3-q5_0;
      };

    };
}
