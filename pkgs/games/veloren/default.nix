{ pkgs,
  # `crate2nix` doesn't support profiles in `Cargo.toml`, so default to release.
  # Otherwise bad performance (non-release is built with opt level 0)
  release ? true,
  cratesToBuild ? [ "veloren-voxygen" "veloren-server-cli" ],
  ...
}:

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

  veloren-src = fetchgitLFS {
    url = "https://gitlab.com/veloren/veloren";
    rev = "30563f59f3d09115b8b6a7d9fddb6cfb1f842e6a";
    sha256 = "sha256-CgFxZP1aktO4tt9UWMz9NswoBP9Y8NXakHjXQ880Mdw=";
  };

  rustOverlay = import ./rustOverlay.nix { inherit pkgs veloren-src; };

  # deps that crates need (for compiling)
  crateDeps = with rustOverlay; {
    libudev-sys = {
      buildInputs = [ libudev ];
      nativeBuildInputs = [ pkg-config ];
    };
    alsa-sys = {
      buildInputs = [ alsaLib ];
      nativeBuildInputs = [ pkg-config ];
    };
    veloren-network = {
      buildInputs = [ openssl ];
      nativeBuildInputs = [ pkg-config ];
    };
    veloren-voxygen = {
      buildInputs = [ xorg.libxcb ];
      nativeBuildInputs = [ ];
    };
  };

  # deps that voxygen needs to function
  # FIXME: Wayland doesn't work (adding libxkbcommon, wayland and wayland-protocols results in a panic)
  voxygenNeededLibs = with rustOverlay; [
    libGL
  ] ++ (with xorg; [
    libX11
    libXcursor
    libXi
    libXrandr
  ]);

  meta = with pkgs.stdenv.lib; {
    description = "Veloren is a multiplayer voxel RPG written in Rust.";
    longDescription = ''
      Veloren is a multiplayer voxel RPG written in Rust.
      It is inspired by games such as Cube World, Legend of Zelda: Breath of the Wild, Dwarf Fortress and Minecraft.
    '';
    homepage = "https://veloren.net";
    upstream = "https://gitlab.com/veloren/veloren";
    license = licenses.gpl3;
    maintainers = [ maintainers.yusdacra ];
    # TODO: Make this work on BSD and Mac OS
    platforms = platforms.linux;
  };

  makeGitCommand = subcommands: name:
    builtins.readFile (pkgs.runCommand name { } ''
      cd ${veloren-src}/.git
      (${pkgs.git}/bin/git ${subcommands}) > $out
    '');

  gitHash = makeGitCommand
    "log -n 1 --pretty=format:%h/%cd --date=format:%Y-%m-%d-%H:%M --abbrev=8"
    "getGitHash";

  gitTag =
    # If the git command errors out we feed an empty string
    makeGitCommand "describe --exact-match --tags HEAD || printf ''"
      "getGitTag";

  # If gitTag has a tag (meaning the commit we are on is a *release*), use it as version, else:
  # Just use the prettified hash we have, if we don't have it the build fails
  version = if gitTag != "" then gitTag else gitHash;
  # Sanitize version string since it might contain illegal characters for a Nix store path
  # Used in the derivation(s) name
  sanitizedVersion = pkgs.stdenv.lib.strings.sanitizeDerivationName version;

  veloren-assets = pkgs.runCommand "makeAssetsDir" { } ''
    mkdir $out
    ln -sf ${veloren-src}/assets $out/assets
  '';

  velorenVoxygenDesktopFile = pkgs.makeDesktopItem rec {
    name = "veloren-voxygen";
    exec = name;
    icon = "${veloren-src}/assets/voxygen/net.veloren.veloren.png";
    comment =
      "Official client for Veloren - the open-world, open-source multiplayer voxel RPG";
    desktopName = "Voxygen";
    genericName = "Veloren Client";
    categories = "Game;";
  };

  veloren-crates = with rustOverlay;
    callPackage "${veloren-src}/nix/Cargo.nix" {
      defaultCrateOverrides = with { inherit crateDeps; };
        defaultCrateOverrides // {
          libudev-sys = _: crateDeps.libudev-sys;
          alsa-sys = _: crateDeps.alsa-sys;
          veloren-network = _: crateDeps.veloren-network;
          veloren-common = _: {
            DISABLE_GIT_LFS_CHECK = true;
            # Declare env values here so that `common/build.rs` sees them
            NIX_GIT_HASH = gitHash;
            NIX_GIT_TAG = gitTag;
          };
          veloren-server-cli = _: {
            name = "veloren-server-cli_${sanitizedVersion}";
            inherit version;
            VELOREN_USERDATA_STRATEGY = "system";
            nativeBuildInputs = [ makeWrapper ];
            postInstall = ''
              wrapProgram $out/bin/veloren-server-cli --set VELOREN_ASSETS ${veloren-assets}
            '';
            meta = meta // {
              longDescription = ''
                ${meta.longDescription}
                "This package includes the server CLI."
              '';
            };
          };
          veloren-voxygen = _: {
            name = "veloren-voxygen_${sanitizedVersion}";
            inherit version;
            VELOREN_USERDATA_STRATEGY = "system";
            inherit (crateDeps.veloren-voxygen) buildInputs;
            nativeBuildInputs =
              crateDeps.veloren-voxygen.nativeBuildInputs ++ [
                copyDesktopItems
                makeWrapper
              ];
            desktopItems = [ velorenVoxygenDesktopFile ];
            postInstall = ''
              wrapProgram $out/bin/veloren-voxygen\
                --set VELOREN_ASSETS ${veloren-assets}\
                --set LD_LIBRARY_PATH ${
                  lib.makeLibraryPath voxygenNeededLibs
                }
            '';
            meta = meta // {
              longDescription = ''
                ${meta.longDescription}
                "This package includes the official client, Voxygen."
              '';
            };
          };
        };
      inherit release pkgs;
    };

  makePkg = name: veloren-crates.workspaceMembers."${name}".build;
in
  (pkgs.lib.genAttrs cratesToBuild makePkg)
