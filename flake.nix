{
  description = "using whisper to translate signal speech notes saved in ~";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { nixpkgs, self, ... }:
    let
      systems = [ "x86_64-linux" ];
      eachSystem =
        f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system} nixpkgs.lib);
      name = "signal-whisper";
    in
    rec {
      packages = eachSystem (
        pkgs: lib:
        (import ./modelPackages.nix { inherit pkgs lib name; })
        // {
          "signal-whisper-link" = import ./link.nix { inherit pkgs lib name; };
        }
      );
      nixosModules.default = nixosModules.signal-whisper;
      nixosModules.signal-whisper = import ./module.nix;
      checks = eachSystem (
        pkgs: lib: {
          nushell = import ./tests/service.nix { inherit pkgs; };
          modelOptions = import ./tests/model-options.nix { inherit pkgs lib; };
          transcription = import ./tests/transcription.nix { inherit pkgs; };
        }
      );
      overlays.default = final: prev: self.packages."x86_64-linux";
      hydraJobs.packages = packages;
    };
}
