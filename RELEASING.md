# Releasing Lineup

> This file describes the 1.x public release process. It has not been updated for the private
> 2.0 rewrite on `unified-app`; treat it as reference only until it is revisited.

Releases are **hybrid**: CI does the heavy, reproducible work (universal build, Developer ID
signing, Apple notarization, GitHub release), and one local command signs the Sparkle appcast.
The Sparkle EdDSA private key — the auto-update root of trust — is deliberately kept **off CI**.

## Cutting a release

1. **Bump the version** in `Resources/Info.plist` — `CFBundleShortVersionString` (marketing,
   e.g. `1.8.1`) and `CFBundleVersion` (monotonic build number, e.g. `15`). Commit it to `main`.

2. **Tag and push** — the tag must equal the Info.plist version (CI enforces this):

   ```bash
   git tag v1.8.1
   git push origin v1.8.1
   ```

   The [`Release`](.github/workflows/release.yml) workflow builds, signs, **notarizes**, and
   publishes a GitHub release with `Lineup-1.8.1.dmg` attached. (~10 min, mostly Apple notary.)

3. **Ship the auto-update** — on a trusted Mac with the Sparkle key:

   ```bash
   ./Scripts/publish-appcast.sh 1.8.1
   ```

   This downloads the notarized DMG the workflow released, EdDSA-signs `web/appcast.xml`, and
   opens a PR. **Merging that PR** triggers `deploy-web.yml`, which publishes the feed to
   `https://lineup.caiano.com/appcast.xml` — that is what prompts existing users to update.

To smoke-test the build/notarize path without releasing, run the workflow manually
(`workflow_dispatch`, `dry_run: true`): it uploads the DMG as an artifact instead of cutting a
release.

## One-time CI setup (repo secrets)

The workflow needs these secrets (`gh secret set <NAME>`), all from the release Mac:

| Secret | What it is |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | base64 of the **Developer ID Application** identity exported as `.p12` |
| `P12_PASSWORD` | the password that `.p12` was exported with |
| `APPLE_ID` | Apple ID email for the notary service |
| `APPLE_TEAM_ID` | Developer team id (`HJ9R8572WN`) |
| `APPLE_APP_SPECIFIC_PASSWORD` | an [app-specific password](https://support.apple.com/en-us/102654) for that Apple ID |

Export the certificate and set the secrets:

```bash
# In Keychain Access: right-click "Developer ID Application: … (HJ9R8572WN)" > Export >
# save as devid.p12 with a password. Then:
gh secret set BUILD_CERTIFICATE_BASE64 < <(base64 -i devid.p12)
gh secret set P12_PASSWORD                 # paste the .p12 password
gh secret set APPLE_ID                     # e.g. henriqueccaiano@gmail.com
gh secret set APPLE_TEAM_ID -b 'HJ9R8572WN'
gh secret set APPLE_APP_SPECIFIC_PASSWORD  # paste an app-specific password
rm devid.p12
```

> **Security note.** These secrets let CI sign and notarize as you. The Sparkle signing key is
> intentionally *not* here — it never leaves your Mac, so a leaked CI secret can't push a
> malicious auto-update to users. Keep it that way.

## Notarization gotcha

If notarization fails with `HTTP 403 … a required agreement … has expired`, the Apple Developer
Program License Agreement needs re-accepting: sign in as the **Account Holder** at
<https://appstoreconnect.apple.com> → Business → Agreements. It can take a few minutes to
propagate before notarization succeeds.
