import 'dart:typed_data';

import 'package:pscore/pscore.dart';

/// Identifies which ACV section supplied a curve.
enum AcvCurveSection {
  /// Curve stored directly after the file header.
  primary,

  /// Channel-indexed curve stored in a version 1 `Crv ` section.
  supplemental,
}

/// Backward-compatible name for the shared interpolation strategy.
typedef AcvInterpolation = PsToneCurveInterpolation;

/// Backward-compatible name for a shared Photoshop tone-curve point.
typedef AcvPoint = PsToneCurvePoint;

/// An immutable Photoshop tone curve and its source metadata.
final class AcvCurve {
  /// Zero-based position of this curve within [section].
  final int index;

  /// Stored or conventionally implied Photoshop channel index.
  ///
  /// Supplemental records store this value explicitly. Primary records infer
  /// it from a version 1 bitmap or ordinary version 4 curve order. Index zero
  /// is composite; Indexed Color mode requires the position helpers on
  /// `AcvFile` because its next three curve slots have special meanings.
  final int channelIndex;

  /// Section that supplied this curve.
  final AcvCurveSection section;

  /// Absolute offset of the section-specific curve entry, or `-1` for new data.
  final int sourceOffset;

  /// Point count declared in the encoded curve record.
  final int declaredPointCount;

  /// Successfully decoded control points in source order.
  final List<AcvPoint> points;

  /// Exact section-specific record bytes, or `null` when not preserved.
  ///
  /// Supplemental records include their two-byte channel index. Primary
  /// records begin directly with their point count.
  final Uint8List? recordData;

  /// Creates an immutable curve with complete source metadata.
  AcvCurve({
    required this.index,
    required this.channelIndex,
    required this.section,
    required this.sourceOffset,
    required this.declaredPointCount,
    required List<AcvPoint> points,
    required Uint8List? recordData,
  }) : points = List<AcvPoint>.unmodifiable(points),
       recordData = recordData == null ? null : Uint8List.fromList(recordData).asUnmodifiableView();

  /// Creates a curve intended for a newly authored or edited ACV document.
  factory AcvCurve.editable({
    required int channelIndex,
    required List<AcvPoint> points,
    AcvCurveSection section = AcvCurveSection.primary,
    int index = 0,
  }) => AcvCurve(
    index: index,
    channelIndex: channelIndex,
    section: section,
    sourceOffset: -1,
    declaredPointCount: points.length,
    points: points,
    recordData: null,
  );

  /// Creates the published two-point identity curve for one [channelIndex].
  factory AcvCurve.identity({
    required int channelIndex,
    AcvCurveSection section = AcvCurveSection.primary,
    int index = 0,
  }) => AcvCurve.editable(
    channelIndex: channelIndex,
    points: const [
      AcvPoint(input: 0, output: 0),
      AcvPoint(input: 255, output: 255),
    ],
    section: section,
    index: index,
  );

  /// Whether every declared point was decoded.
  bool get isComplete => points.length == declaredPointCount;

  /// Whether the curve satisfies every published structural constraint.
  bool get isOfficial => declaredPointCount >= 2 && declaredPointCount <= 19 && isComplete && points.every((point) => point.isInOfficialRange) && hasStrictlyIncreasingInputs;

  /// Whether every control point maps its input to the same output.
  bool get isIdentity => _toneCurve.isIdentity;

  /// Whether input coordinates are strictly increasing in source order.
  bool get hasStrictlyIncreasingInputs => _toneCurve.hasStrictlyIncreasingInputs;

  /// Evaluates a raw 0 through 255 [input] coordinate.
  ///
  /// Values outside the first and last control points use the nearest endpoint.
  /// Natural cubic interpolation can overshoot; [clampOutput] limits the result
  /// to the conventional 0 through 255 output range.
  double evaluate(
    double input, {
    AcvInterpolation interpolation = AcvInterpolation.naturalCubic,
    bool clampOutput = true,
  }) => _toneCurve.evaluate(
    input,
    interpolation: interpolation,
    clampOutput: clampOutput,
  );

  /// Evaluates an [input] normalized to the 0 through 1 range.
  double evaluateNormalized(
    double input, {
    AcvInterpolation interpolation = AcvInterpolation.naturalCubic,
    bool clampOutput = true,
  }) =>
      evaluate(
        input * 255,
        interpolation: interpolation,
        clampOutput: clampOutput,
      ) /
      255;

  /// Builds an evenly sampled raw-coordinate lookup table.
  Float64List toLookupTable({
    int size = 256,
    AcvInterpolation interpolation = AcvInterpolation.naturalCubic,
    bool clampOutput = true,
  }) => _toneCurve.toLookupTable(
    size: size,
    interpolation: interpolation,
    clampOutput: clampOutput,
  );

  /// Builds an evenly sampled 8-bit lookup table.
  Uint8List toUint8LookupTable({
    int size = 256,
    AcvInterpolation interpolation = AcvInterpolation.naturalCubic,
  }) => _toneCurve.toUint8LookupTable(
    size: size,
    interpolation: interpolation,
  );

  /// Shared format-neutral curve semantics for these points.
  PsToneCurve get _toneCurve => PsToneCurve(points: points);

  /// Returns an editable replacement with optional channel and point changes.
  ///
  /// Source offsets and encoded record bytes are cleared because they no longer
  /// describe the newly authored curve.
  AcvCurve copyWith({
    int? channelIndex,
    List<AcvPoint>? points,
  }) {
    final List<AcvPoint> replacementPoints = points ?? this.points;
    return AcvCurve(
      index: index,
      channelIndex: channelIndex ?? this.channelIndex,
      section: section,
      sourceOffset: -1,
      declaredPointCount: replacementPoints.length,
      points: replacementPoints,
      recordData: null,
    );
  }
}
