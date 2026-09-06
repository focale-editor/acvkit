# ACV format support

This document describes the structures accepted and emitted by AcvKit. Multibyte integers are unsigned and big-endian. Adobe's published Curves file description is the normative reference for the fields; behavior beyond those fields is deliberately surfaced rather than guessed.

## Common header

Every ACV file starts with two 16-bit values:

| Field | Type | Meaning |
| --- | --- | --- |
| Version | `uint16` | Published values are 1 and 4 |
| Header value | `uint16` | Version 1 channel bitmap or version 4 curve count |

An unsupported version still has a safely bounded common header. Tolerant decoding exposes that version and header value, then preserves the remaining payload as `trailingData`. Strict decoding rejects it.

## Curve record

Both layouts ultimately use the same point representation:

| Field | Type | Meaning |
| --- | --- | --- |
| Point count | `uint16` | Published range is 2–19 |
| Output | `uint16` | Vertical point coordinate, published range 0–255 |
| Input | `uint16` | Horizontal point coordinate, published range 0–255 |

The output coordinate is stored before the input coordinate. AcvKit models it as `AcvPoint(input: ..., output: ...)` to match the way applications normally evaluate a transfer function.

The published identity record is two points, `(input 0, output 0)` and `(input 255, output 255)`. AcvKit's broader `isIdentity` helper also recognizes collinear intermediate identity points.

Tolerant mode retains the entire 16-bit coordinate domain and original point order. It warns about coordinates beyond 255, counts outside 2–19, and duplicate or descending inputs. Such curves remain inspectable and permissively encodable, but evaluation rejects ambiguous non-increasing inputs.

## Version 4 layout

Version 4 interprets the common header value as the number of consecutive curve records. A curve has no stored channel field. In the ordinary layout, its zero-based position implies its channel index: the first curve is composite, followed by active channels. Adobe permits up to 19 curves because Indexed Color uses a specialized layout.

```text
uint16 version = 4
uint16 curveCount
curve curves[curveCount]
```

Strict output requires 1–19 records, a matching count, and sequential model channel indices. Tolerant input can retain larger counts up to configured resource limits.

Indexed Color is the ordering exception. Position zero remains composite; positions one, two, and three address the red, green, and blue portions of the color table and all conceptually apply to the first image channel. Active alpha channels 2–16 then occupy positions 4–18. Because ACV does not store its target color mode, the decoder cannot infer this interpretation. Applications that know the target mode can use `indexedColorTableCurve` and `indexedColorAlphaCurve`; `curveAtPosition` always exposes the unambiguous encoded order.

## Version 1 layout

Version 1 interprets the common header value as a 16-bit channel bitmap. One primary curve follows for every set bit, in ascending bit order:

```text
uint16 version = 1
uint16 channelBitmap
curve primaryCurves[popcount(channelBitmap)]
```

This makes sparse channel selections representable but limits the primary section to channels 0–15. `AcvFile.primaryChannelIndices` exposes the exact implied ordering.

### Optional `Crv ` section

A version 1 file can append a newer, explicitly indexed representation:

```text
char marker[4] = "Crv "
uint16 version = 4
uint32 curveCount
repeat curveCount times:
  uint16 channelIndex
  curve channelCurve
```

This section expands the count and channel fields and removes reliance on bitmap order. AcvKit exposes both representations rather than discarding the older primary curves. `effectiveCurves` prefers a non-empty supplemental section for ordinary rendering; `primaryCurves` and `supplementalSection.curves` remain independently accessible.

An unknown supplemental version is not parsed using a guessed layout. In tolerant mode, the bytes beginning with `Crv ` become opaque trailing data, allowing exact reconstruction and future support.

## Decoding modes and recovery

`AcvDecodeMode.strict` enforces the published constraints and rejects:

- versions other than 1 and 4;
- empty or excessive official curve and point counts;
- values outside 0–255;
- non-increasing input points;
- unknown supplemental versions;
- unrecognized trailing bytes and structural truncation.

`AcvDecodeMode.tolerant` reports those issues through `AcvFile.warnings`. When a record is truncated, the decoder returns all complete preceding curves and preserves bytes beginning at the damaged record. It does not scan forward for a guessed boundary.

Supplemental channel indices use their complete unsigned 16-bit field. Adobe does not state that they must be unique, so AcvKit retains duplicates without inventing a restriction. Ordered iteration exposes every record; `curveForChannel` deliberately returns the last matching record.

Resource limits are separate from compatibility policy and always throw. Defaults limit total input, curves per section, points per curve, and aggregate points. This prevents small headers from causing unbounded allocations or work.

## Exact preservation and encoding

The model separates semantic values from optional source copies:

| Option | Preserved data |
| --- | --- |
| `preserveCurveData` | Complete section-specific bytes for every decoded curve |
| `preserveSourceData` | Complete original file |
| `preserveTrailingData` | Undecodable or unknown suffix |

`recordData` includes the explicit channel field for supplemental curves. These copies are diagnostic; the encoder writes current semantic point values rather than silently preferring stale source records.

Strict encoding emits only a published structure. Permissive encoding retains declared counts and other representable values, making a tolerant decoded file byte-exact when its opaque suffix was preserved. If `trailingByteCount` exceeds the retained byte length, encoding with trailing output fails explicitly instead of pretending that omitted bytes are recoverable.

## Evaluation and lookup tables

The file does not encode how points should be interpolated. AcvKit supplies two deterministic application helpers:

- piecewise linear interpolation;
- a natural cubic spline whose second derivative is zero at both endpoints.

The spline choice is compatible with a common smooth-curves interpretation but is not presented as hidden ACV metadata or a guarantee of pixel-identical Photoshop rendering. Applications can use the raw points with another monotone or proprietary interpolator.

`evaluate` uses raw 0–255 coordinates. `evaluateNormalized` converts both axes to 0–1. `toLookupTable` and `toUint8LookupTable` sample the complete 0–255 input domain evenly. Results are clamped by default because cubic splines can overshoot between legal points.

## Integration guidance

An image editor should decode ACV outside its presentation layer and retain the numeric `channelIndex`. RGB convenience getters are appropriate only after the target color mode is known. Apply the composite and component curves according to the editor's adjustment pipeline rather than assuming the file declares a composition order—it does not.

For preset browsing, source and per-record copies can be disabled after semantic decoding. For non-destructive editing or format diagnostics, preserve unknown suffixes and show warnings to the import layer. Large lookup tables can be built once per curve and reused by the renderer.

AcvKit has no Flutter dependency. Focale can later depend on it from its data layer and translate `AcvPoint` or lookup tables into its own adjustment model. This package creation does not modify Focale.

## References

- [Adobe Photoshop File Formats Specification, Curves file format](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/)
- [FFmpeg `curves` filter implementation](https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/vf_curves.c)
