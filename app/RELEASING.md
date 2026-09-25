# Packaging Einstein Ring

End users install the app from a DMG or ZIP. These instructions are for maintainers on an Apple silicon Mac with Xcode Command Line Tools.

## Build and verify

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `app/Info.plist`.
2. Put `cosmos.mp4` and `cosmos.png` in the repository root. For the original render, download them from release `v1.0` and run `shasum -a 256 -c app/media.sha256`. Rendering a custom video is also supported; update the pinned media release and checksums when changing the official artwork.
3. Run `./build-app.sh` and `./tests/verify-app.sh`.
4. On a Mac with a graphical session and Low Power Mode off, run `"build/app-package/Einstein Ring.app/Contents/MacOS/EinsteinRing" --smoke-test`. This briefly opens wallpaper windows, checks decoded frames and pause/resume, then exits. It skips welcome/migration dialogs and does not register a login item or change the system wallpaper.

The build creates `dist/Einstein-Ring.dmg`, `dist/Einstein-Ring.zip`, and `dist/SHA256SUMS.txt`. The DMG includes an Applications shortcut and offline installation instructions. The wallpaper media stay outside Git and are bundled in each download.

CI on macOS 15 validates compilation, the ad-hoc signature, app metadata, media loading, and missing/corrupt resource diagnostics. It uploads artifacts without publishing a release. It does not exercise a real user's login session or Gatekeeper quarantine.

## Developer ID signing and notarization

Without an Apple Developer ID certificate, the build uses an ad-hoc signature. This is sufficient to run on Apple silicon but does not establish an identity trusted by Gatekeeper. Document the first-open Privacy & Security approval; never tell users to disable Gatekeeper or strip quarantine attributes.

For a notarized release, install a **Developer ID Application** certificate in your keychain and create a `notarytool` keychain profile using Apple's [notarization instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Do not commit certificates, passwords, or API keys.

```sh
# Use an existing keychain identity and stored notarization profile.
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="einstein-ring-notary" \
./build-app.sh
```

The script enables hardened runtime, signs the app, submits it to Apple, staples the ticket, then signs/notarizes/staples the DMG. It switches the DMG's instructions to the notarized version automatically. Once the published release is notarized, update the README's first-open section and release notes accordingly.

## Release checklist

- Mount the DMG, confirm the app and Applications shortcut are present, and run the resource checks on the mounted app. Also extract and validate the ZIP.
- Copy the app to Applications, open from Finder, and test welcome, pause/resume, quit, and reopening. Confirm the previous desktop appears on quit.
- Enable and disable Open at Login; check macOS Login Items. Before claiming login-session coverage, verify a logout/login cycle on a test account.
- Test display sleep, Low Power Mode, desktop occlusion, multiple monitors, Spaces, and fullscreen apps when those configurations are available.
- Test a browser-downloaded quarantined copy on another Mac; local packaging does not reproduce Gatekeeper's download checks.
- Publish a release targeting the tested commit, attaching the DMG, ZIP, and checksum file. Include minimum OS, Apple silicon requirement, installation steps, and current notarization status. Keep the v1.0 media assets available because CI uses them.

## Platform scope

The app targets `arm64-apple-macos13.0`; macOS 13 is the API floor for `SMAppService.mainApp`. Building with that target checks availability, but does not substitute for running on each supported macOS version. Intel builds are not currently distributed.
