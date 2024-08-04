{
  description = "Build DDI -- a safe Rust wrapper for DD";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    fenix,
    advisory-db,
    ...
  } @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      flake = {
        nixosModules = let
        in {
          default = {pkgs, ...}: {
            imports = [
              ./module.nix
              ({...}: {
                environment.systemPackages = [
                  (pkgs.writeShellApplication {
                    name = "ddi";
                    runtimeInputs = [
                      pkgs.ddi
                      pkgs.coreutils
                    ];
                    text = ''
                      exec ddi status=progress "$@"
                    '';
                  })

                  (pkgs.writeShellApplication {
                    name = "dd";
                    runtimeInputs = [
                      pkgs.ddi
                      pkgs.coreutils
                    ];
                    text = ''
                      echo "WARNING: It\`s safer to call \`ddi\` than \`dd\`, so \`dd\` is hard-wrapped to \`ddi\` in Dolomite."
                      echo "If you want to call the OG command, use \`dangerous-dd\`"
                      echo "Otherwise, always use \`ddi\`"
                      exec ddi "$@"
                    '';
                    meta.priority = -1;
                  })
                  (pkgs.writeShellApplication {
                    name = "dangerous-dd";
                    runtimeInputs = [pkgs.coreutils];
                    text = ''
                      exec dd "$@"
                    '';
                  })
                ];
                nixpkgs.overlays = [
                  (self: super: {
                    ddi = self.outputs.packages.${pkgs.system}.default;
                    #packages.x86_64-linux.default
                    # inherit ddi;
                  })
                ];
              })
            ];
          };
        };
      };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem = {system, ...}: let
        # flake-utils.lib.eachDefaultSystem (system: let
        pkgs = nixpkgs.legacyPackages.${system};

        inherit (pkgs) lib;

        craneLib = crane.lib.${system};
        src = craneLib.cleanCargoSource (craneLib.path ./.);

        # Common arguments can be set here to avoid repeating them later
        commonArgs = {
          inherit src;
          strictDeps = true;

          buildInputs =
            [
              # Add additional build inputs here
            ]
            ++ lib.optionals pkgs.stdenv.isDarwin [
              # Additional darwin specific inputs can be set here
              pkgs.libiconv
            ];

          # Additional environment variables can be set directly
          # MY_CUSTOM_VAR = "some value";
        };

        craneLibLLvmTools =
          craneLib.overrideToolchain
          (fenix.packages.${system}.complete.withComponents [
            "cargo"
            "llvm-tools"
            "rustc"
          ]);

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        ddi = craneLib.buildPackage (commonArgs
          // {
            inherit cargoArtifacts;
          });
      in {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit ddi;

          # Run clippy (and deny all warnings) on the crate source,
          # again, resuing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          ddi-clippy = craneLib.cargoClippy (commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            });

          ddi-doc = craneLib.cargoDoc (commonArgs
            // {
              inherit cargoArtifacts;
            });

          # Check formatting
          ddi-fmt = craneLib.cargoFmt {
            inherit src;
          };

          # Audit dependencies
          ddi-audit = craneLib.cargoAudit {
            inherit src advisory-db;
          };

          # Audit licenses
          ddi-deny = craneLib.cargoDeny {
            inherit src;
          };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on `ddi` if you do not want
          # the tests to run twice
          ddi-nextest = craneLib.cargoNextest (commonArgs
            // {
              inherit cargoArtifacts;
              partitions = 1;
              partitionType = "count";
            });
        };

        packages =
          {
            default = ddi;
          }
          // lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
            ddi-llvm-coverage = craneLibLLvmTools.cargoLlvmCov (commonArgs
              // {
                inherit cargoArtifacts;
              });
          };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};

          # Additional dev-shell environment variables can be set directly
          # MY_CUSTOM_DEVELOPMENT_VAR = "something else";

          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [
            # pkgs.ripgrep
          ];
        };
      };
    };
}
