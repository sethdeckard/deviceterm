# Releasing DeviceTerm

The release workflow runs locally. `make release` builds, signs, notarizes, and
staples the artifacts on your Mac. `make publish` creates the GitHub release
and updates the Homebrew tap.

See [`BUILDING.md`](BUILDING.md) for the signing and bundle pipeline.

## One-Time Setup

- [ ] Confirm that the DeviceTerm repository is public. GitHub Releases,
  Sparkle, Homebrew, and the published-source obligations in
  `THIRD_PARTY_NOTICES.md` depend on public access.

- [ ] Copy `.env.release.example` to `.env.release` and configure a Developer
  ID Application identity:

  ```sh
  cp .env.release.example .env.release
  security find-identity -v -p codesigning
  ```

- [ ] Configure notarization in `.env.release`. Prefer `NOTARY_PROFILE` for a
  `notarytool` Keychain profile. Otherwise provide `APPLE_ID`,
  `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`.

- [ ] Clone the Homebrew tap and point the publisher at it:

  ```sh
  git clone git@github.com:sethdeckard/homebrew-tap.git ../homebrew-tap
  ```

  Set `DEVICETERM_TAP_DIR` in `.env.release` when the checkout is not at the
  default `../homebrew-tap` path.

- [ ] Authenticate the GitHub CLI:

  ```sh
  gh auth status
  ```

- [ ] Install the Sparkle release tools. Ensure `generate_keys` and
  `generate_appcast` are available. Set `SPARKLE_BIN_DIR` when
  `generate_appcast` is not on `PATH`.

- [ ] Generate the Sparkle EdDSA key with `generate_keys`. Keep the private key
  in the login Keychain. Replace the `SUPublicEDKey` placeholder in
  `Sources/App/Resources/Info.plist` with the printed public key.

> **Back up the Sparkle private key before the first release.** Existing
> installations trust this key for future updates. Losing it requires those
> users to reinstall manually before they can trust a replacement key.

Export the private key with `generate_keys -x`, store it offline or in a
password manager, and never commit it.

Developer ID certificates and notarization credentials can be regenerated
through the Apple Developer account. You may also export the Developer ID
certificate as a `.p12` when preparing another release machine.

## Scrub Public Assets

Before publishing a new image or binary asset, remove EXIF, C2PA, XMP, local
paths, and macOS extended attributes. Preserve the original image encoding
when removing a metadata chunk is sufficient; otherwise re-encode it.

Use ExifTool or another format-aware tool that supports the asset's container.
Inspect embedded metadata before editing it, including the C2PA/JUMBF group:

```sh
exiftool -a -G1 -s <file>
exiftool -jumbf:all -G3 -b -j -u -struct <file>
```

Remove the EXIF, XMP, C2PA, and path-bearing fields reported by the inspector.
For a writable format, this ExifTool command removes the three standard
metadata groups without deleting an ICC color profile:

```sh
exiftool -EXIF:all= -XMP:all= -JUMBF:all= -overwrite_original <file>
```

If the tool cannot delete embedded metadata from that format, re-encode the
asset and inspect the result. Check that required color and orientation
information still renders correctly. Repeat the format-aware inspection, then
run these secondary checks:

```sh
strings <file> | grep -iE 'c2pa|gpt-image|xmp|exif|/Users/|file://'  # heuristic; expect empty
xattr -c <file>
xattr <file>                                                        # expect empty
```

## Prepare the Release

### Set the Version and Notes

- [ ] Choose the public version according to SemVer. During `0.x`, a minor
  release may break the public CLI or JSON contract. Patch releases remain
  compatible. Starting with `1.0`, breaking public changes require a new major
  version.

- [ ] Set the release version with `make bump VERSION=x.y.z`, or edit
  `DeviceTermVersion.current` in
  `Sources/DaemonProtocol/DeviceTermVersion.swift` and the README download
  line by hand; `make verify` fails if those two disagree. Everything else
  derives from the constant at build and publish time: the bundled app and
  daemon Info.plists, the DMG name, the `v<version>` tag, and the Homebrew
  cask. The committed plists and cask template hold `0.0.0` placeholders.
  Editing those placeholder fields does not set the release version.

- [ ] Review `DaemonProtocolInfo.wireVersion` separately. It identifies the
  internal app, daemon, CLI, and shim RPC contract during an update. Change it
  only with an incompatible wire change, not for an ordinary product release.
  `DaemonInfo.version` must continue to mirror it.

- [ ] Write the GitHub release notes at
  `release/release-notes-<version>.md`. If this file is absent,
  `make publish` asks GitHub to generate the notes.

- [ ] Write the in-app update notes at
  `release/release-notes-<version>.html`. `make publish` embeds this file in
  the Sparkle appcast. If it is absent, the update popover reports that no
  release notes are available.

- [ ] Scrub any new public assets as described above.

### Run the Release Gates

- [ ] Run the full repository gate:

  ```sh
  make verify
  ```

- [ ] Build the release tree with Xcode 26.4 and Xcode 26.6. These are the
  currently covered build toolchains. Xcode 27 beta remains unsupported until
  its build failure is resolved.

- [ ] Run `make probe` in every Simulator-services environment claimed by the
  release. Record each result in
  `Sources/CoreSimulatorBridge/as-tested.md`.

> **The Simulator live track shuts down every running Simulator.** Save any
> work in them before continuing.

- [ ] Run the default Simulator live track for every claimed iOS runtime:

  ```sh
  make test-live
  ```

- [ ] Complete the
  [watchOS manual checklist](../Tests/Manual/watchos-checklist.md) for every
  claimed watchOS runtime. Its setup runs the automated watch live track before
  the required visual checks.

- [ ] Run the physical-device track for every physical-device and OS
  combination claimed by the release:

  ```sh
  make test-device-live
  ```

  This track does not reboot or shut down the physical device. Physical-device
  stream compatibility is independent of Simulator services and compiler
  compatibility.

### Commit and Build

- [ ] Commit the complete release-ready tree.

- [ ] Push the release commit to GitHub before publishing. When the version tag
  does not already exist, `gh release create` creates it from the latest state
  of the default branch. The remote default branch must therefore contain the
  release commit.

- [ ] Confirm that the tracked tree is clean:

  ```sh
  git status --short
  ```

  `make release` refuses tracked changes because the About panel records the
  source commit used for the build.

- [ ] Build the release:

  ```sh
  make release
  ```

  This produces the signed, notarized, and stapled
  `release/deviceterm-<version>.dmg`, along with the intermediate release
  artifacts.

## Publish the Release

Publishing changes GitHub and the Homebrew tap. First inspect the planned
version, checksum, appcast URL, and cask:

```sh
scripts/publish-release.sh --dry-run
```

When the dry run is correct:

```sh
make publish
```

The publisher performs these operations in order:

1. Calculate the DMG checksum.
2. Generate the EdDSA-signed Sparkle appcast.
3. Create the GitHub release and upload the DMG and `appcast.xml`.
4. Render, commit, and push the Homebrew cask.

The cask is pushed last so it cannot point at a release artifact that failed to
upload.

## Verify the Published Release

- [ ] Confirm that GitHub release `v<version>` points at the release commit.
  Verify that the commit shown in **About DeviceTerm** is reachable in the
  public repository.

- [ ] Confirm that the release contains
  `deviceterm-<version>.dmg` and `appcast.xml`, and that the `SUFeedURL`
  resolves to the published appcast.

- [ ] Download the DMG from GitHub Releases, mount it, drag DeviceTerm to
  Applications, and launch it. Verify Gatekeeper acceptance:

  ```sh
  spctl --assess --type exec /Applications/DeviceTerm.app
  ```

- [ ] Install through Homebrew and launch the app:

  ```sh
  brew install --cask sethdeckard/tap/deviceterm
  ```

- [ ] Run `deviceterm version` inside a DeviceTerm tab. Confirm the public
  release version and expected internal RPC wire version.

- [ ] Choose **DeviceTerm ▸ Check for Updates…**. Confirm that it reports no
  newer update and that the update indicator dismisses normally.

- [ ] Confirm that `LICENSE` exists at the mounted DMG root and at
  `/Applications/DeviceTerm.app/Contents/Resources/LICENSE`.

- [ ] Confirm that `Contents/Resources/` contains
  `THIRD_PARTY_NOTICES.md` and the `licenses/` directory.

- [ ] Confirm that the Kitty-derived shell integration carries
  `GPL-3.0.txt` at both packaged locations:

  ```text
  Contents/Resources/ghostty/ghostty/shell-integration/GPL-3.0.txt
  Contents/Resources/Libghostty_GhosttyKitResources.bundle/Resources/ghostty/ghostty/shell-integration/GPL-3.0.txt
  ```

- [ ] Open **DeviceTerm ▸ About DeviceTerm**. Verify the copyright, GPL
  notice, **Read the license** link, and **Third-Party Notices** link.

## Maintenance Notes

### Remove the Login Item During Uninstall

The embedded daemon registers through `SMAppService`. Homebrew's `zap` removes
DeviceTerm application data but does not unregister the login item.

Quit DeviceTerm, open **System Settings ▸ General ▸ Login Items & Extensions**,
and remove or disable the DeviceTerm background item when fully uninstalling
the app. Daemon idle exit stops the process but does not unregister the
service.

### Change the Apple Team

Changing from one Apple Team to another is a credential change, not a code
change. `PeerIdentity.swift` reads the daemon's Team ID from its signature and
derives the host bundle identifier from the daemon bundle identifier.

1. Create a Developer ID Application certificate for the new Team.
2. Update `CODESIGN_IDENTITY` and the notarization credentials.
3. Keep the `com.deviceterm` bundle identifier.
4. Keep the existing Sparkle EdDSA key so installed copies continue to trust
   updates.
5. Expect macOS to request permissions again when it associates them with the
   new signing identity.
