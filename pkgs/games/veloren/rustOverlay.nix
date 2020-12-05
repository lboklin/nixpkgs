{ pkgs, veloren-src, ... }:
let
  mozPkgs = pkgs.fetchFromGitHub {
    owner = "mozilla";
    repo = "nixpkgs-mozilla";
    rev = "8c007b60731c07dd7a052cce508de3bb1ae849b4";
    sha256 = "1zybp62zz0h077zm2zmqs2wcg3whg6jqaah9hcl1gv4x8af4zhs6";
  };

  rustChannel =
    builtins.mapAttrs
      (name: value:
        (if name == "rust" then value.override { extensions = [ "rust-src" ]; } else value))
      ((pkgs.callPackage "${mozPkgs}/package-set.nix" {}).rustChannelOf {
        rustToolchain = builtins.toPath "${veloren-src}/rust-toolchain";
        sha256 = "sha256-P4FTKRe0nM1FRDV0Q+QY2WcC8M9IR7aPMMLWDfv+rEk=";
      });

in
  pkgs.appendOverlays [
    (final: prev: {
      rustc = rustChannel.rust.override {
        extensions = [ "rust-src" ];
      };
    })
  ]
