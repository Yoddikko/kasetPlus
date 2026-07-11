# Releasing KasetPlus

How to cut a new KasetPlus release and make in-app auto-update work. Written to
be followed step by step (by a human or an AI agent).

## How updates reach users (the moving parts)

KasetPlus auto-updates with **Sparkle**. Three pieces have to agree:

1. **The app** embeds, in its `Info.plist` (set by `Scripts/build-app.sh`):
   - `SUFeedURL` → `https://raw.githubusercontent.com/Yoddikko/kasetPlus/main/appcast.xml`
   - `SUPublicEDKey` → our EdDSA **public** key.
2. **`appcast.xml`** (served from that URL, i.e. `main`) lists the latest build:
   its version, download URL, size, and an **EdDSA signature**.
3. **The private key** signs each release's zip. The app verifies that signature
   against its embedded public key and refuses anything that doesn't match.

On launch (and periodically) the app fetches `appcast.xml`, compares the
newest `sparkle:version` to its own `CFBundleVersion`, and if it's higher and
the signature verifies, it offers "Update available". So a release is only
"seen" once its item is in `appcast.xml` **on `main`**, signed with our key.

> This fork originally inherited **upstream's** key + appcast (the feed pointed
> at `sozercan/kaset`), so our own releases were never offered. We now use our
> own key and our own appcast — see the note at the bottom about the key.

## The signing key

- Private key: held **outside the repo** at `~/kaset-sparkle-private-key.txt`
  (also usable as the CI secret `SPARKLE_PRIVATE_KEY`). **Never commit it.**
- Public key: `ev8BOn34ZbVJn2FonYjxi2tAtNDJmgCET3NcklUJl9o=`, in
  `Scripts/build-app.sh` as `SUPublicEDKey`.
- Sparkle tools (after any `swift build`) live at
  `.build/artifacts/sparkle/Sparkle/bin/{sign_update,generate_keys}`.

If the private key is ever lost, generate a new pair (`generate_keys`), put the
new public key in `Scripts/build-app.sh`, and ship it — but existing installs
(old public key) can't verify updates signed with the new key, so those users
must re-download once. New installs auto-update fine from there.

## Manual / local release (what we actually do today)

Actions on this fork aren't enabled, so releases are built and signed locally.
Versions are tagged `v0.12.0-kp.N` (marketing version stays `0.12.0`; the
`-kp.N` suffix and the bumped build number differentiate builds).

```bash
cd /path/to/kasetPlus

# 1. Bump the build number (MUST increase every release, or Sparkle won't see
#    the new build as newer). Keep MARKETING_VERSION unless it's a real bump.
#    e.g. 22 -> 23:
sed -i '' 's/^BUILD_NUMBER=.*/BUILD_NUMBER=23/' version.env

# 2. Build the release app (release config, ad-hoc signed).
Scripts/build-app.sh

# 3. Zip it with ditto (preserves the code signature Sparkle needs).
rm -f /tmp/KasetPlus.zip
ditto -c -k --keepParent .build/app/KasetPlus.app /tmp/KasetPlus.zip

# 4. Sign the zip → prints:  sparkle:edSignature="..." length="..."
SU=.build/artifacts/sparkle/Sparkle/bin/sign_update
"$SU" --ed-key-file ~/kaset-sparkle-private-key.txt /tmp/KasetPlus.zip
# (sanity: "$SU" --verify /tmp/KasetPlus.zip "<edSignature>"  → exit 0, no error)

# 5. Create the GitHub release with the zip (asset name stays KasetPlus.zip).
gh release create v0.12.0-kp.N /tmp/KasetPlus.zip \
  --repo Yoddikko/kasetPlus \
  --title "KasetPlus v0.12.0-kp.N" \
  --notes-file /tmp/relnotes.md \
  --latest
```

Then update **`appcast.xml`** — add a NEW `<item>` at the top of `<channel>`
(remove or keep older ones), filling in the values from steps 1 and 4:

```xml
<item>
    <title>Version 0.12.0-kp.N</title>
    <sparkle:releaseNotesLink>https://github.com/Yoddikko/kasetPlus/releases/tag/v0.12.0-kp.N</sparkle:releaseNotesLink>
    <pubDate>Sat, 11 Jul 2026 16:13:51 +0000</pubDate>   <!-- date -u +"%a, %d %b %Y %H:%M:%S +0000" -->
    <enclosure
        url="https://github.com/Yoddikko/kasetPlus/releases/download/v0.12.0-kp.N/KasetPlus.zip"
        sparkle:version="23"                <!-- = BUILD_NUMBER from step 1 -->
        sparkle:shortVersionString="0.12.0" <!-- = MARKETING_VERSION -->
        length="46523797"                   <!-- = length from step 4 -->
        type="application/octet-stream"
        sparkle:edSignature="+Nmy...Bg=="/> <!-- = edSignature from step 4 -->
    <sparkle:minimumSystemVersion>15.4</sparkle:minimumSystemVersion>
</item>
```

Finally commit and push so the feed on `main` updates:

```bash
git add version.env appcast.xml            # + Scripts/build-app.sh only if the key changed
git commit -m "Release v0.12.0-kp.N"
git push origin main
```

Verify the chain:

```bash
curl -s https://raw.githubusercontent.com/Yoddikko/kasetPlus/main/appcast.xml | grep -E "sparkle:version|<title>Version"
curl -sIL https://github.com/Yoddikko/kasetPlus/releases/download/v0.12.0-kp.N/KasetPlus.zip | grep -iE "HTTP/|content-length"
```

## Release notes style

Match upstream's tone: start with a "## What's New" heading and a support line
that links to **our** Ko-fi (`https://ko-fi.com/yodddd`, handle `yodddd` from
`.github/FUNDING.yml` — NOT upstream's `sozercan`), then emoji-headed `###`
sections with **bold** feature names and short bullets. See the kp.5 release for
a template.

## Automated release via CI (optional, better long-term)

`.github/workflows/release.yml` already builds, Developer-ID-signs, **notarizes**,
Sparkle-signs, creates the release, and updates `appcast.xml` on a tag push. It
has never run because this is a fork (Actions disabled) and its secrets aren't
set. To switch to it:

1. Repo → **Actions** tab → enable workflows.
2. Add repo secrets: `SPARKLE_PRIVATE_KEY` (contents of
   `~/kaset-sparkle-private-key.txt`), and for notarization `MACOS_CERTIFICATE`,
   `MACOS_CERTIFICATE_PWD`, `MACOS_KEYCHAIN_PWD` + Apple notarization creds.
3. Release by pushing a tag: `git push origin v0.12.0-kp.N` — CI does the rest.
   (`gh release create` alone does NOT trigger it; the tag must be pushed via git.)

The CI path also **notarizes** the app, which the local build does not — so
CI releases won't trip macOS Gatekeeper for downloaders.
