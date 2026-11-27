# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: the **Security** tab › **Report a vulnerability**
(private vulnerability reporting). Don't open a public issue for one. Flick reads files you open and parses
untrusted media (MP4/MOV, Matroska, and the formats FFmpeg decodes), so a crash or memory error triggered by a crafted
file is in scope.

## What a release is

- Releases are built from this repository by `make-app.sh`, signed with an Apple **Developer ID** certificate with the
  **hardened runtime**, **notarized** by Apple and **stapled**, so Gatekeeper opens them without a warning, offline.
- Each release asset is a zip holding the disk image. The release page lists the zip's **SHA-256**; check it with
  `shasum -a 256 Flick-<version>.zip`.
- Flick makes no network connections, needs no camera, microphone or Accessibility permission, and is not sandboxed
  (a direct download rather than an App Store app). Its only hardened-runtime exception is
  `com.apple.security.cs.disable-library-validation`, so the separately shipped FFmpeg libraries can be replaced
  (LGPL).
- The bundled FFmpeg is the unmodified upstream source, built by `Tools/build-ffmpeg.sh`.

## Building a signed copy yourself

```bash
FLICK_SIGN_IDENTITY="Developer ID Application: …" ./make-app.sh
FLICK_SIGN_IDENTITY="Developer ID Application: …" FLICK_NOTARY_PROFILE=<profile> Tools/notarize.sh
```

`./make-app.sh` alone makes an ad-hoc signed build that runs on your own Mac only.
