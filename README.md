# Alauda’s OpenTelemetry Collector Distribution

## Update collector version

1. Update `OCB_VERSION` in the `Makefile` to select the desired upstream version.
2. Update `manifest.yaml` to select the desired upstream version and component selection for the product release.
3. Run `make build` to perform a local build test.

## Release

After creating a new Release with a tag in the format `vx.y.z-rn` (for example, `v0.145.0-r0`), the image build action will be triggered automatically.

## Local build

```bash
make build
```
