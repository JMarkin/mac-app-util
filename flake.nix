{
  description = "Description for the project";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      perSystem = { config, self', inputs', pkgs, system, ... }: {
        devShells.default = {
          packages = [
            pkgs.mac-app-util
          ];
        };
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "mac-app-util";
          version = "2025-10-19";
          src = ./.;
          buildInputs = with pkgs; [
            bash
            dockutil
            rsync
            findutils
            jq
          ];

          installPhase = ''
            mkdir -p $out/bin
            cp main.bash $out/bin/mac-app-util
            chmod +x $out/bin/mac-app-util
          '';

          postPatch = ''
            patchShebangs $out/bin/mac-app-util
          '';
        };
      };
      flake = {
        homeManagerModules.default =
          { pkgs
          , lib
          , config
          , ...
          }:
          {
            options = with lib; {
              targets.darwin.mac-app-util.enable = mkOption {
                type = types.bool;
                default = builtins.hasAttr pkgs.stdenv.system self.packages;
                example = true;
                description = "Whether to enable mac-app-util home manager integration";
              };
            };
            config = lib.mkIf config.targets.darwin.mac-app-util.enable {
              home.activation = {
                trampolineApps =
                  let
                    mac-app-util = self.packages.${pkgs.stdenv.system}.default;
                  in
                  lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                    fromDir="$HOME/Applications/Home Manager Apps"
                    toDir="$HOME/Applications/Home Manager Trampolines"
                    ${mac-app-util}/bin/mac-app-util sync-trampolines "$fromDir" "$toDir"
                  '';
              };
            };
          };
        darwinModules.default =
          { config
          , pkgs
          , lib
          , ...
          }:
          {
            options = {
              # Technically this isn’t a “service” but this seems like the most
              # polite place to put this?
              services.mac-app-util.enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                example = false;
              };
            };
            config = lib.mkIf config.services.mac-app-util.enable {
              system.activationScripts.postActivation.text =
                let
                  mac-app-util = self.packages.${pkgs.stdenv.system}.default;
                in
                ''
                  ${mac-app-util}/bin/mac-app-util sync-trampolines "/Applications/Nix Apps" "/Applications/Nix Trampolines"
                '';
            };
          };

      };
    };
}
