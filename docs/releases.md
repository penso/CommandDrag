# Releasing CommandDrag

CI builds a universal **arm64 + x86_64** macOS 13+ app on every push to `main`
and every pull request. Its downloadable artifact is ad-hoc signed and retained
for seven days. CI does not need credentials.

Release tags (`v1.0.0`, `v1.1.0-rc.1`, etc.) trigger a separate workflow that:

1. Imports a Developer ID certificate into a temporary keychain.
2. Builds and signs a universal app with the hardened runtime and a secure timestamp.
3. Submits it to Apple's notarization service and requires an accepted result.
4. Staples and validates the notarization ticket, then checks Gatekeeper acceptance.
5. Publishes `CommandDrag-vX.Y.Z-universal.zip` and `SHA256SUMS` to GitHub Releases.

Tags with a suffix create GitHub prereleases. The app's short version is the
numeric `X.Y.Z`; its build number comes from the release workflow run number.
Releases fail if credentials are missing; they never silently publish unsigned builds.

## One-time Apple setup

You need an active Apple Developer Program membership.

### Export the Developer ID certificate

1. Open **Keychain Access** and select **My Certificates** in your login keychain.
2. Find **Developer ID Application: Fabien Penso (VJAHQVZ96V)**. Expand it to
   confirm that its private key is present. Use a **Developer ID Application**
   certificate, not Apple Development or Developer ID Installer.
3. Select the certificate and its private key, then choose **File → Export Items**.
4. Save as a `.p12` outside the repository and protect it with a strong password.
   Approve Keychain Access's export prompt yourself.

If there is no private key, export from the Mac where the certificate was created,
or create a new Developer ID Application certificate through your developer account.

### Obtain a notarization API key

1. Open [App Store Connect](https://appstoreconnect.apple.com/).
2. Go to **Users and Access → Integrations → App Store Connect API → Team Keys**.
   An account administrator may need to enable API access first.
3. Generate a team key with **Developer** access, or use an existing suitable key.
4. Download the `.p8` private key (Apple only permits the download once), and note
   its **Key ID** and the team's **Issuer ID**. Keep the key outside the repository.

This workflow uses a team key with an Issuer ID, not an individual API key or an
Apple ID app-specific password. No App Store app listing is needed for notarization.

## Configure GitHub

Run these commands from a trusted local terminal. Replace the example file paths;
do not commit credential files or paste their contents into issues or chat.
`gh secret set` without redirected input prompts for a value without echoing it.

```sh
base64 -i /path/to/CommandDrag-DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_BASE64 --repo penso/CommandDrag
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --repo penso/CommandDrag
gh secret set APPLE_API_PRIVATE_KEY --repo penso/CommandDrag < /path/to/AuthKey_KEYID.p8
gh secret set APPLE_API_KEY_ID --repo penso/CommandDrag
gh secret set APPLE_API_ISSUER_ID --repo penso/CommandDrag
gh variable set DEVELOPER_ID_APPLICATION --repo penso/CommandDrag \
  --body 'Developer ID Application: Fabien Penso (VJAHQVZ96V)'
```

Equivalent settings are available in **Repository Settings → Secrets and variables
→ Actions**. The certificate identity is a repository **variable**; the five other
values are repository **secrets**. Secrets are only read by the release job, not PR CI.

Check names without displaying values:

```sh
gh secret list --repo penso/CommandDrag
gh variable list --repo penso/CommandDrag
```

## Publish a version

Once CI is green and the credentials are configured:

```sh
git switch main
git pull --ff-only
git tag -a v1.0.0 -m 'CommandDrag 1.0.0'
git push origin v1.0.0
gh run list --workflow release.yml
```

The release workflow also supports **Run workflow** with an existing tag. This is
useful after fixing missing credentials; it always checks out that exact tag.
It does not overwrite an existing release. Use a new version for changed source.

## Local builds

`bash build.sh` builds both architectures by default. For a faster native-only
development build, use `ARCHS=arm64 bash build.sh` (or `ARCHS=x86_64` on Intel).

To sign locally without notarizing:

```sh
SIGN_IDENTITY='Developer ID Application: Fabien Penso (VJAHQVZ96V)' bash build.sh
```

Signing alone is not notarization. Use the release workflow to produce the
stapled, notarized archive intended for downloads.
