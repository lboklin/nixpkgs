{ pkgs, ... }:

let
  fetchgitLFS = args:
    let
      gitconfig = pkgs.writeText "gitconfig" ''
        [filter "lfs"]
          clean = "git-lfs clean -- %f"
          process = "git-lfs filter-process"
          required = true
          smudge = "git-lfs smudge -- %f"
      '';

    in
      (pkgs.fetchgit (args // { leaveDotGit = true; })).overrideAttrs
        (oldAttrs: {
          fetcher = pkgs.writeText "git-lfs.sh" ''
            #! /usr/bin/env bash

            export HOME=$TMPDIR
            mkdir -p $HOME/.config/git/
            cp ${gitconfig} $HOME/.config/git/config

            bash ${oldAttrs.fetcher} $@
          '';

          nativeBuildInputs =
            oldAttrs.nativeBuildInputs or [] ++ [
              pkgs.git-lfs
            ];
        });

  velorenSrc = fetchgitLFS {
    url = "https://gitlab.com/veloren/veloren";
    rev = "30563f59f3d09115b8b6a7d9fddb6cfb1f842e6a";
    sha256 = "sha256-CgFxZP1aktO4tt9UWMz9NswoBP9Y8NXakHjXQ880Mdw=";
  };

in
  import "${velorenSrc}/nix" { system = "x86_64-linux"; }
