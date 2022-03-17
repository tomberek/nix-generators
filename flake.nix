# First draft of this flake include a large amount of cruft to be compatible
# with both pre and post Nix 2.6 APIs.
#
# The expected state is to support bundlers of the form:
# bundlers.<system>.<name> = drv: some-drv;

{
  description = "Example bundlers";

  inputs.nix-utils.url = "github:juliosueiras-nix/nix-utils";
  inputs.nix-bundle.url = "github:matthewbauer/nix-bundle";
  inputs.go-appimage-src = {
    url = "github:probonopd/go-appimage";
    flake = false;
  };


  outputs = { self, nixpkgs, nix-bundle, nix-utils, go-appimage-src }: let
      # System types to support.
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Nixpkgs instantiated for supported system types.
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });

      # Backwards compatibility helper for pre Nix2.6 bundler API
      program = p: with builtins; with p; "${
        if p?meta && p.meta?mainProgram then
          meta.mainProgram
          else (parseDrvName (unsafeDiscardStringContext p.name)).name
      }";
  in {
    packages = forAllSystems (system: {
      go-appimage = nixpkgsFor.${system}.buildGo117Module {
        pname = "go-appimage";
        version = "0.0.0";
        src = go-appimage-src;
        patches = [./mod.patch];
        vendorSha256 = "sha256-aSDw+g+ii2jGWHW5id6IbRa/hE2w70WA59NlXJFN2MQ=";
        #deleteVendor = true;
        subPackages = ["src/appimagetool"];
      };
    });

    # Backwards compatibility helper for pre Nix2.6 bundler API
    defaultBundler = {__functor = s: {...}@arg:
      (if arg?program && arg?system then
        nix-bundle.bundlers.nix-bundle arg
       else with builtins; listToAttrs (map (system: {
            name = system;
            value = drv: self.bundlers.${system}.toArx drv;
          }) supportedSystems));
      };

    bundlers = let n =
      (forAllSystems (system: {
        toAppImage = drv: with nixpkgsFor.${system}; let
            closure = closureInfo {rootPaths = [drv];};
            prog = program drv;
            system = drv.system;
            nixpkgs' = nixpkgs.legacyPackages.${system};
            #nix-bundle = import (nix-bundle + "/appimage-top.nix") { nixpkgs' = nixpkgs; };

            muslPkgs = import nixpkgs {
              localSystem.config = "x86_64-unknown-linux-musl";
            };

            pkgs = nixpkgs.legacyPackages.${system};
            #appimagetool = pkgs.callPackage (nix-bundle + "/appimagetool.nix") {};
            appimage = pkgs.callPackage (nix-bundle + "/appimage.nix") {
                inherit appimagetool;
            };
            appdir = pkgs.callPackage (nix-bundle + "/appdir.nix") { inherit muslPkgs; };

            env = appdir {
              name = "hello";
              target =
              buildEnv {
                name = "hello";
                paths = [drv (
                  runCommand "appdir" {buildInputs = [imagemagick];} ''
                    mkdir -p $out/share/applications
                    mkdir -p $out/share/icons/hicolor/256x256/apps
                    convert -size 256x256 xc:#990000 ${nixpkgs.lib.attrByPath ["meta" "icon"] "$out/share/icons/hicolor/256x256/apps/icon.png" drv}
                    cat <<EOF > $out/share/applications/out.desktop
                    [Desktop Entry]
                    Type=Application
                    Version=1.0
                    Name=${drv.pname or drv.name}
                    Comment=${nixpkgs.lib.attrByPath ["meta" "description"] "Bundled by toAppImage" drv}
                    Path=${drv}/bin
                    Exec=${prog}
                    Icon=icon
                    Terminal=true
                    Categories=${nixpkgs.lib.attrByPath ["meta" "categories"] "Utility" drv};
                    EOF
                    ''
                  )];
              };
            };
            # envResolved = runCommand "hello" {} ''
            #     cp -rL ${env} $out
            #   '';
          in
          runCommand drv.name {
            buildInputs = [#self.packages.${system}.go-appimage file squashfsTools
            patchelfUnstable appimagekit ];
          dontFixup = true;
        } ''
          cp -rL ${env}/*.AppDir out.AppDir
          chmod +w -R ./out.AppDir
          cp out.AppDir/usr/share/applications/out.desktop out.AppDir
          cp out.AppDir/usr/share/icons/hicolor/256x256/apps/icon.png out.AppDir/.DirIcon
          cp out.AppDir/usr/share/icons/hicolor/256x256/apps/icon.png out.AppDir/.
          ARCH=x86_64 appimagetool out.AppDir
          #ls -alh ./out.AppDir/usr/
          #ls -alh ./out.AppDir/usr/bin
          #mkdir bin
          #cat <<EOF > bin/patchelf
          ##!/bin/sh
          #true
          #EOF
          #chmod +x ./bin/patchelf
          #export PATH=./bin:$PATH
          #ARCH=x86_64 appimagetool -s deploy ./out.AppDir/usr/share/applications/*.desktop
          cp *.AppImage $out
          '';

        # Backwards compatibility helper for pre Nix2.6 bundler API
        toArx = drv: (nix-bundle.bundlers.nix-bundle ({
          program = if drv?program then drv.program else (drv.outPath + program drv);
          inherit system;
        })) // (if drv?program then {} else {name=
          (builtins.parseDrvName drv.name).name;});

      toRPM = drv: nix-utils.bundlers.rpm {inherit system; program=drv.outPath + program drv;};

      toDEB = drv: nix-utils.bundlers.deb {inherit system; program=drv.outPath + program drv;};

      toDockerImage = {...}@drv:
        (nixpkgs.legacyPackages.${system}.dockerTools.buildLayeredImage {
          name = drv.name;
          tag = "latest";
          contents = [ drv ];
      });

      toBuildDerivation = drv:
        (import ./report/default.nix {
          inherit drv;
          pkgs = nixpkgsFor.${system};}).buildtimeDerivations;

      toReport = drv:
        (import ./report/default.nix {
          inherit drv;
          pkgs = nixpkgsFor.${system};}).runtimeReport;

      identity = drv: drv;
    }
    ));
    in with builtins;
    # Backwards compatibility helper for pre Nix2.6 bundler API
    listToAttrs (map
      (name: {
        inherit name;
        value = builtins.trace "The bundler API has been updated to require the form `bundlers.<system>.<name>`. The previous API will be deprecated in Nix 2.7. See `https://github.com/NixOS/nix/pull/5456/`"
        ({system,program}@drv: self.bundlers.${system}.${name}
          (drv // {
            name = baseNameOf drv.program;
            outPath = dirOf (dirOf drv.program);
          }));
        })
      (attrNames n.x86_64-linux))
      //
      n;
  };
}
