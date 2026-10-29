{
  pkgs,
  lib,
}:
let
  evaluate = options:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../module.nix
        ({ ... }: {
          services.signal-whisper = { enable = true; } // options;
          system.stateVersion = "24.05";
        })
      ];
    }).config;
  modelPackages = import ../modelPackages.nix {
    inherit pkgs lib;
    name = "signal-whisper";
  };
  customModel = pkgs.writeText "custom-model.bin" "fake-model";
  failedAssertions = config: builtins.filter (check: !check.assertion) config.assertions;
  hasModelError = config: prefix:
    lib.any (check: lib.hasPrefix prefix check.message) (failedAssertions config);
  modelPath = config:
    let
      entry = lib.findFirst (value: lib.hasPrefix "SIGNAL_WHISPER_MODEL=" value) ""
        config.systemd.services.signal-whisper.serviceConfig.Environment;
    in
    lib.removePrefix "SIGNAL_WHISPER_MODEL=" entry;
in
assert modelPath (evaluate { modelName = "tiny.en"; }) ==
  "${modelPackages.tiny_en}/${modelPackages.tiny_en.name}.bin";
assert modelPath (evaluate { model = customModel; }) == toString customModel;
assert hasModelError (evaluate { })
  "Either `services.signal-whisper.modelName`";
assert hasModelError (evaluate { model = customModel; modelName = "tiny.en"; })
  "Only one of `services.signal-whisper.modelName`";
assert hasModelError (evaluate { modelName = "not-a-model"; })
  "`services.signal-whisper.modelName` must";
assert hasModelError (evaluate { modelName = "signal-whisper-tiny_en"; })
  "`services.signal-whisper.modelName` must";
pkgs.runCommand "signal-whisper-model-options" { } "touch $out"
