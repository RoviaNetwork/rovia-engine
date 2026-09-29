# rovia-engine

Rovia engine integration: Xray and sing-box adapters, canonical-to-engine
config compilation, and (planned) deterministic artifact builds.

Part of [RoviaNetwork](https://github.com/RoviaNetwork). Core contracts come
from [RoviaNetwork/rovia-core](https://github.com/RoviaNetwork/rovia-core)
(pinned `exact`, never a floating branch); the app lives in
[RoviaNetwork/rovia](https://github.com/RoviaNetwork/rovia).

## Decision

Production engine: **Xray via libXray** (`engines.lock.json` in the app repo
pins `v26.9.9`). Reasons: VLESS/REALITY reference implementation, MPL-2.0 /
MIT licensing shippable in the App Store (sing-box is GPL-3.0-or-later),
one-Go-runtime-per-process respected (engine lives in the extension only).

## Verify

```sh
swift test --package-path engines/xray
swift test --package-path engines/singbox
```
