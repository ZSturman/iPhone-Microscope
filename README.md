# iPhone Microscope

A native camera workbench with an iPhone companion, bounded image transport, focusing and calibration tools.

**Status:** macOS 14+ and Xcode are required. Physical camera controls, optical accuracy, permissions and device installation require separate checks. Digital zoom is not optical magnification. Configure your own signing team.

[Project portfolio](https://zacharysturman.com/projects/iphone-microscope)

## Quick start

```sh
xcodegen generate
./scripts/build.sh
```

## Usage

```sh
./scripts/run.sh --demo
```

## How it works

Swift packages separate camera processing and calibration from the native interface. An encrypted paired companion link carries bounded foreground camera frames from an iPhone.

## Testing

```sh
swift test --scratch-path build/SwiftPM
```

See [validation and next steps](docs/NEXT_STEPS.md) for the checks performed on this snapshot. Automated fixture tests do not establish physical-device compatibility.

## Configuration and privacy

This is a curated source snapshot, published November 12, 2026. Configure your own endpoints, credentials and signing identities. Private development history, local environment files, personal recordings, runtime databases, signing materials and deployment automation are excluded. Deployment and device installation are explicit operator actions.

## License and attribution

Existing licenses and third-party notices apply to the files they cover. Publication of this snapshot does not grant a new license to original material; no additional license is granted where none is supplied.
