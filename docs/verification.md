# Verifying release downloads

The app and DMG are Developer ID signed and notarized by Apple. Releases made
with the hardened pipeline also publish the files below. **v1.0.0 and v1.0.1
predate these additional attestations** and only include their original checksums.

| File | Purpose |
| --- | --- |
| `SHA256SUMS`, `SHA512SUMS` | Hashes of the final DMG, ZIP, SBOM, and build metadata |
| `*.sig`, `*.crt` | Sigstore keyless signature and short-lived certificate for each artifact and checksum list |
| `provenance.sigstore.json` | GitHub's signed SLSA build-provenance bundle |
| `CommandDrag-vX.Y.Z.cdx.json` | CycloneDX 1.6 SBOM: the app, adapted yabai source, system frameworks, and packaging tools |
| `build-info.json` | Source commit, compiler/SDK, target architectures, and packaging-tool versions |

Packaging tools are listed as build tools, not bundled runtime dependencies.
Apple frameworks are identified as OS-provided; SkyLight is optional. The
adapted yabai protocol is identified by its shipped source hash because its
original upstream commit was not recorded.

## Check provenance

Install a recent [GitHub CLI](https://cli.github.com/) and authenticate with
`gh auth login` if needed. Replace the example version with the release to verify:

```sh
VERSION=v1.0.2
FILE="CommandDrag-$VERSION-universal.dmg"
gh release download "$VERSION" --repo penso/CommandDrag --pattern "$FILE"
gh attestation verify "$FILE" --repo penso/CommandDrag \
  --signer-workflow penso/CommandDrag/.github/workflows/release.yml \
  --source-ref "refs/tags/$VERSION" --deny-self-hosted-runners
```

For an independently known source commit, also pass `--source-digest FULL_COMMIT_SHA`.
To use the downloaded attestation instead of fetching it from GitHub, add
`--bundle provenance.sigstore.json`. The verification checks artifact bytes,
the GitHub workflow identity, and the release ref, not just a checksum supplied
by the same download server.

## Verify Sigstore signatures

With [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) installed,
download the `.sig` and `.crt` files alongside the artifact:

```sh
gh release download "$VERSION" --repo penso/CommandDrag \
  --pattern "$FILE.sig" --pattern "$FILE.crt"
cosign verify-blob \
  --signature "$FILE.sig" --certificate "$FILE.crt" \
  --certificate-identity "https://github.com/penso/CommandDrag/.github/workflows/release.yml@refs/tags/$VERSION" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com "$FILE"
```

The release workflow uses cosign 2.6.5's detached-signature format. No additional
long-lived signing secret is needed; GitHub OIDC supplies the workflow identity.

## Check all downloaded files

Download the complete release into a new directory, then run:

```sh
shasum -a 256 -c SHA256SUMS
shasum -a 512 -c SHA512SUMS
```

Checksums detect corruption; the signatures and provenance authenticate where
those bytes came from. Signing and publication fail closed if any verification fails.
