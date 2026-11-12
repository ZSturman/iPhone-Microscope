# Validation and next steps

Snapshot prepared November 12, 2026.

## Current state

macOS 14+ and Xcode are required. Physical camera controls, optical accuracy, permissions and device installation require separate checks. Digital zoom is not optical magnification. Configure your own signing team.

## Validation

PASS: 12 Swift package tests. No physical cameras, microphone or device installation were used.

Publication checks: the exact Git tree and its new history are scanned locally with Gitleaks before the repository becomes public. Reviewed scanner exceptions are restricted to synthetic fixture secrets, an invalid test token, a browser preference name and the published NIST AES test vector. Private histories are not included.

## Next action

Follow the README quick start, run the documented focused tests, then use isolated inputs for a manual walkthrough. Real hardware, release signing, background behavior and live-server compatibility are outside this publication check.
