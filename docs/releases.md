# Releasing CommandDrag

CI builds a universal **arm64 + x86_64** macOS 13+ app on every push to `main`
and every pull request. Its downloadable artifact is ad-hoc signed and retained
for seven days. CI does not need credentials. Both CI and releases are gated by
zizmor (pedantic mode), release-contract tests, and a hash-locked packaging
dependency vulnerability audit. The audits also run weekly.

Release tags (`v1.0.0`, `v1.1.0-rc.1`, etc.) trigger a separate workflow that:

1. Requires the owner to run the workflow from the release tag in the canonical repository.
2. Verifies the tag's commit is on `main` and waits for successful main CI on that exact SHA.
3. Imports a Developer ID certificate into a temporary keychain and builds/signs the universal app.
4. Notarizes the app, staples its ticket, and checks Gatekeeper acceptance.
5. Packages the drag-to-install DMG, then signs, notarizes, staples, and checks it too.
6. Generates a CycloneDX SBOM, build metadata, and SHA-256/SHA-512 checksums of the final files.
7. In a separate job, keyless-signs the final artifacts using Sigstore and verifies those signatures.
8. Generates GitHub build-provenance attestations bound to the same source tag and commit.
9. In a publish-only job, rechecks the tag, checksums, and provenance before creating the release.

The Apple-signing job has only a read-only GitHub token. The attestation job has
OIDC/attestation permissions but no Apple secrets or release-write access. Only
the final publication job can write a GitHub Release. All external actions use
full commit SHAs and checkouts disable credential persistence. Dependabot tracks
action and packaging-tool updates with a seven-day cooldown.

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
git tag -a v1.0.2 -m 'CommandDrag 1.0.2'
git push origin v1.0.2
gh run list --workflow release.yml
```

For a credential or network failure, rerun the failed run, or dispatch from the
same tag (select the tag in **Run workflow**, not `main`):

```sh
gh workflow run release.yml --ref v1.0.2 -f tag=v1.0.2
```

The tag, checked-out source, workflow, and attested source SHA must agree.
Tooling changes now require a new tag; the earlier tooling-only retry mechanism
was removed to avoid attesting a different commit from the one actually built.
Existing releases and tags are not overwritten. A failed or cancelled CI run
blocks signing; rerun CI successfully before retrying the release.

See [verifying downloads](verification.md) for the checksum, Sigstore, and
provenance commands. The original `v1.0.0` and `v1.0.1` releases predate this
attestation pipeline; their assets are not retroactively replaced.

## Local builds

`bash build.sh` builds both architectures by default. For a faster native-only
development build, use `ARCHS=arm64 bash build.sh` (or `ARCHS=x86_64` on Intel).

To sign locally without notarizing:

```sh
SIGN_IDENTITY='Developer ID Application: Fabien Penso (VJAHQVZ96V)' bash build.sh
```

Signing alone is not notarization. Use the release workflow to produce the
stapled, notarized archive intended for downloads.

## Build a DMG locally

DMG packaging uses a few pinned Python build tools; these are not app runtime
dependencies. Finder layout is written directly, so packaging also works on CI
without AppleScript permissions or a running Finder session.

```sh
bash build.sh
python3 -m venv build/dmg-venv
build/dmg-venv/bin/python -m pip install --require-hashes --only-binary=:all: -r Scripts/dmg-requirements.txt
bash Scripts/package-dmg.sh
```

This produces `build/CommandDrag-universal.dmg`. The packaging script mounts the
result read-only and verifies the Applications symlink, both CPU architectures,
the app signature, and icon positions. A local DMG is not signed or notarized;
the release workflow performs those steps using GitHub secrets.

The layout lives in `Scripts/dmg-settings.py`. To regenerate its standard and
Retina instruction backgrounds:

```sh
xcrun clang @compile_flags.txt -Werror -O2 -framework Cocoa \
  Scripts/generate-dmg-background.m -o build/generate-dmg-background
build/generate-dmg-background
```
