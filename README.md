# AcvKit

AcvKit is a pure Dart codec for Adobe Photoshop Curves (`.acv`) files. It reads and writes both published container layouts, exposes immutable editable control points, evaluates curves without Flutter or native code, and safely handles untrusted or forward-compatible input.

The package is designed for editors such as Focale. Focale integration is intentionally kept outside this initial package change.

## Supported data

- Version 4 files with source-ordered composite and channel curves.
- Version 1 files with bitmap-selected primary channels.
- Optional version 1 `Crv ` sections with explicit 16-bit channel indices and 32-bit curve counts.
- The complete unsigned 16-bit representation retained in tolerant mode, including nonstandard coordinates beyond 255.
- Unknown versions, malformed optional sections, truncated later curves, and trailing bytes preserved for diagnosis and byte-exact reconstruction.
- Strict and tolerant decoding with configurable file, curve, per-curve point, and aggregate point limits.
- Strict standards-compliant writing and permissive reconstruction of representable nonstandard input.
- Linear and natural cubic interpolation, normalized evaluation, floating-point tables, and 8-bit lookup tables.

## Reading a file

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';

final Uint8List bytes = await File('cinematic.acv').readAsBytes();
final AcvFile file = AcvDecoder.decode(bytes);

for (final AcvCurve curve in file.effectiveCurves) {
  print('channel ${curve.channelIndex}: ${curve.points}');
}

final AcvCurve? red = file.redCurve;
final Uint8List? redLookup = red?.toUint8LookupTable();
```

Channel zero is the composite curve. For an ordinary RGB adjustment, channels one, two, and three conventionally represent red, green, and blue. Indexed Color is the documented exception: three consecutive slots alter the red, green, and blue portions of its color table before later alpha-channel curves. `curveAtPosition`, `indexedColorTableCurve`, and `indexedColorAlphaCurve` expose that layout without pretending the file contains a color-mode tag.

`effectiveCurves` selects a non-empty channel-indexed supplemental section when present, then falls back to the primary section. Applications that need forensic fidelity can inspect both lists independently.

## Writing and editing

```dart
final AcvFile file = AcvFile.versionFour(
  curves: [
    AcvCurve.editable(
      channelIndex: 0,
      points: const [
        AcvPoint(input: 0, output: 0),
        AcvPoint(input: 96, output: 72),
        AcvPoint(input: 255, output: 255),
      ],
    ),
  ],
);

final Uint8List encoded = AcvEncoder.encode(file);
await File('edited.acv').writeAsBytes(encoded);
```

Strict encoding is the default. It requires published versions, matching counts, 2–19 points per curve, coordinates from 0 through 255, and strictly increasing inputs. `AcvEncodeMode.permissive` is intended for reconstruction and format research; it writes any values that fit their binary fields.

## Reusable `dart:convert` API

`AcvCodec` implements `Codec<AcvFile, List<int>>` and keeps decoding and encoding policies together in one immutable value:

```dart
const AcvCodec codec = AcvCodec(
  decodeOptions: AcvDecodeOptions(mode: AcvDecodeMode.strict),
  encodeOptions: AcvEncodeOptions(mode: AcvEncodeMode.strict),
);

final AcvFile file = codec.decode(bytes);
final Uint8List encoded = codec.encode(file);
```

The `List<int>` binary type allows composition with standard codecs such as `base64`; direct `encode` calls still return `Uint8List`. `AcvEncoder` and `AcvDecoder` are also configurable `Converter` implementations. Every conversion consumes or produces one complete in-memory ACV file rather than an incremental byte stream.

## Strict, tolerant, and bounded decoding

Tolerant decoding is the default. It returns safely decoded earlier data, records an `AcvWarning`, and retains the undecodable suffix whenever no reliable record boundary remains. Strict mode turns the first compatibility issue into an `AcvFormatException`:

```dart
final AcvFile file = AcvDecoder.decode(
  bytes,
  options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
);
```

Configured resource limits always fail, even in tolerant mode. Preservation switches independently control curve-record copies, the complete source copy, and opaque trailing bytes. Disable them for a memory-minimal preset browser; retain trailing bytes when permissive byte reconstruction matters.

The bundled corpus inspector accepts individual files or directories:

```console
dart run tool/inspect_acv.dart --strict --round-trip ACV_EXAMPLES
```

## Interpolation

ACV stores only control points, not an interpolation algorithm. AcvKit therefore exposes the choice explicitly:

- `AcvInterpolation.linear` joins control points directly;
- `AcvInterpolation.naturalCubic` uses a natural cubic spline and is the default convenience for smooth tone tables.

Both modes hold the nearest endpoint outside the covered input interval. Natural splines can overshoot, so evaluation and lookup helpers clamp to 0–255 by default. Disable clamping when an application needs the mathematical result.

See [docs/ACV.md](docs/ACV.md) for the binary layout, compatibility rules, preservation model, and integration guidance.

## References

- [Adobe Photoshop File Formats Specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/)
- [FFmpeg curves filter source](https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/vf_curves.c)

AcvKit is an independent implementation and is not affiliated with or endorsed by Adobe.
