{
  description = "Userspace WireGuard implementation in Rust, with VRF support";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.crane.url = "github:ipetkov/crane";
  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, crane, treefmt-nix }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      forSystems = sys: f: nixpkgs.lib.genAttrs sys (system: f system nixpkgs.legacyPackages.${system});

      treefmtEval = forSystems systems (system: pkgs: treefmt-nix.lib.evalModule pkgs {
        projectRootFile = "flake.nix";
        programs.nixpkgs-fmt.enable = true;
      });

      boringtunPkg = pkgs:
        let
          craneLib = crane.mkLib pkgs;
          src = craneLib.cleanCargoSource self;

          commonArgs = {
            inherit src;
            pname = "boringtun";
            version = "0.7.1-vrf-patch";
            doCheck = false;
            meta = {
              description = "Userspace WireGuard® implementation in Rust";
              homepage = "https://github.com/cloudflare/boringtun";
              license = pkgs.lib.licenses.bsd3;
              platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
              mainProgram = "boringtun-cli";
            };
          };

          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        in
        craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
        });

    in
    {
      formatter = forSystems systems (system: pkgs: treefmtEval.${system}.config.build.wrapper);

      packages = forSystems systems (system: pkgs: rec {
        default = boringtun;
        boringtun = boringtunPkg pkgs;
      });

      devShells = forSystems systems (_: pkgs: {
        default = pkgs.mkShell {
          name = "boringtun-dev";
          buildInputs = with pkgs; [ rustc cargo rust-analyzer rustfmt ];
        };
      });

      checks = forSystems systems (system: pkgs:
        let
          boringtunPkgs = pkgs.extend (_final: prev: {
            boringtun = boringtunPkg pkgs;
          });

          vrfCheck =
            if builtins.elem system linuxSystems then {
              vrf-test = boringtunPkgs.testers.runNixOSTest {
                imports = [ ./test-boringtun-vrf.nix ];
              };
            } else { };
        in
        vrfCheck // {
          formatting = treefmtEval.${system}.config.build.check self;
        }
      );
    };
}
