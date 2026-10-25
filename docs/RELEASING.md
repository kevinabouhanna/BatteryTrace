# Releasing

## Cutting a release

Every release is a tag on `main`, after a pull request is merged:

```sh
git checkout main && git pull
git tag v0.7.0 && git push origin v0.7.0
```

The **Release** workflow (`.github/workflows/release.yml`) then:

1. runs the tests;
2. builds the universal app with the tag's version (`make universal`);
3. signs and notarizes it, **if the signing secrets exist** (below);
4. packages `BatteryTrace.dmg` (`Scripts/make-dmg.sh`), and signs and
   notarizes that too;
5. checks the bundle's version matches the tag;
6. publishes the release with install notes, which explain **Open Anyway**
   only when the build isn't signed.

Add a "What's new in X.Y.Z" section at the top of the notes afterwards. The
app's **Check for Updates…** shows that section, up to the next heading, so
keep it first and keep it short.

## Signing and notarization

Without a Developer ID, releases are ad-hoc signed and macOS asks for **Open
Anyway** on each new version. With one, add five repository secrets
(**Settings › Secrets and variables › Actions**). The workflow signs whenever
all five exist, and skips signing if any is missing.

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_P12` | Your "Developer ID Application" certificate and its private key, exported from Keychain Access as a `.p12`, then base64-encoded: `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you gave the `.p12` when exporting it |
| `APPLE_ID` | The Apple ID of your developer account |
| `APPLE_TEAM_ID` | Your team ID, from developer.apple.com › Membership |
| `APPLE_APP_PASSWORD` | An app-specific password for that Apple ID, from appleid.apple.com › Sign-In and Security. Not your account password. |

The workflow imports the certificate into a temporary keychain, then runs
`Scripts/sign-and-notarize.sh`:

- **The app:** every helper executable, then the app, with the hardened
  runtime and a secure timestamp. No entitlements: the Release build's
  `get-task-allow` is dropped, which notarization requires. Then a zip goes to
  `notarytool`, and the ticket is stapled to the app.
- **The disk image:** built from the stapled app, then signed, notarized and
  stapled itself.

To try the signing on your own Mac without notarizing:

```sh
make universal
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARIZE=0 \
  Scripts/sign-and-notarize.sh app "build/DerivedDataUniversal/Build/Products/Release/Battery Trace.app"
```

Once releases are signed, update the README's Install section: the
**Open Anyway** steps no longer apply.
