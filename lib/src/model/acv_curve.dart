import 'dart:typed_data';

/// Identifies which ACV section supplied a curve.
enum AcvCurveSection {
  /// Curve stored directly after the file header.
  primary,

  /// Channel-indexed curve stored in a version 1 `Crv ` section.
  supplemental,
}

/// Selects how values between ACV control points are calculated.
enum AcvInterpolation {
  /// Joins adjacent control points with straight segments.
  linear,

  /// Uses a natural cubic spline with zero endpoint curvature.
  naturalCubic,
}

/// One input-to-output control point from an ACV curve.
final class AcvPoint {
  /// Horizontal input coordinate as stored in the file.
  final int input;

  /// Vertical output coordinate as stored in the file.
  final int output;

  /// Creates one immutable control point.
  const AcvPoint({
    required this.input,
    required this.output,
  });

  /// Whether both coordinates use the published 0 through 255 range.
  bool get isInOfficialRange => input >= 0 && input <= 255 && output >= 0 && output <= 255;

  /// Input coordinate normalized to the conventional 0 through 1 range.
  double get normalizedInput => input / 255;

  /// Output coordinate normalized to the conventional 0 through 1 range.
  double get normalizedOutput => output / 255;

  @override
  bool operator ==(Object other) => other is AcvPoint && other.input == input && other.output == output;

  @override
  int get hashCode => Object.hash(input, output);

  @override
  String toString() => 'AcvPoint(input: $input, output: $output)';
}

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
  bool get isIdentity => points.isNotEmpty && points.every((point) => point.input == point.output);

  /// Whether input coordinates are strictly increasing in source order.
  bool get hasStrictlyIncreasingInputs {
    for (int index = 1; index < points.length; index++) {
      if (points[index].input <= points[index - 1].input) {
        return false;
      }
    }
    return true;
  }

  /// Evaluates a raw 0 through 255 [input] coordinate.
  ///
  /// Values outside the first and last control points use the nearest endpoint.
  /// Natural cubic interpolation can overshoot; [clampOutput] limits the result
  /// to the conventional 0 through 255 output range.
  double evaluate(
    double input, {
    AcvInterpolation interpolation = AcvInterpolation.naturalCubic,
    bool clampOutput = true,
  }) {
    final _AcvCurveEvaluator evaluator = _AcvCurveEvaluator(points: points);
    final double value = evaluator.evaluate(input, interpolation);
    return clampOutput ? value.clamp(0, 255).toDouble() : value;
  }

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
  }) {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive');
    }
    final _AcvCurveEvaluator evaluator = _AcvCurveEvaluator(points: points);
    final Float64List result = Float64List(size);
    for (int index = 0; index < size; index++) {
      final double input = size == 1 ? 0 : index * 255 / (size - 1);
      final double value = evaluator.evaluate(input, interpolation);
      result[index] = clampOutput ? value.clamp(0, 255).toDouble() : value;
    }
    return result;
  }

  /// Builds an evenly sampled 8-bit lookup table.
  Uint8List toUint8LookupTable({
    int size = 256,
    AcvInterpolation interpolation = AcvInterpolation.naturalCubic,
  }) {
    final Float64List values = toLookupTable(
      size: size,
      interpolation: interpolation,
    );
    final Uint8List result = Uint8List(values.length);
    for (int index = 0; index < values.length; index++) {
      result[index] = values[index].round();
    }
    return result;
  }

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

/// Efficiently evaluates one validated sequence of control points.
final class _AcvCurveEvaluator {
  /// Control points in strictly increasing input order.
  final List<AcvPoint> _points;

  /// Natural-spline second derivatives, calculated only when needed.
  List<double>? _secondDerivatives;

  /// Creates an evaluator after checking that interpolation is well-defined.
  _AcvCurveEvaluator({
    required List<AcvPoint> points,
  }) : _points = points {
    if (points.isEmpty) {
      throw StateError('An empty ACV curve cannot be evaluated');
    }
    for (int index = 1; index < points.length; index++) {
      if (points[index].input <= points[index - 1].input) {
        throw StateError('ACV curve inputs must be strictly increasing before evaluation');
      }
    }
  }

  /// Evaluates [input] with the selected [interpolation].
  double evaluate(double input, AcvInterpolation interpolation) {
    if (_points.length == 1 || input <= _points.first.input) {
      return _points.first.output.toDouble();
    }
    if (input >= _points.last.input) {
      return _points.last.output.toDouble();
    }
    final int upperIndex = _findUpperIndex(input);
    final int lowerIndex = upperIndex - 1;
    return switch (interpolation) {
      AcvInterpolation.linear => _evaluateLinear(input, lowerIndex, upperIndex),
      AcvInterpolation.naturalCubic => _evaluateNaturalCubic(input, lowerIndex, upperIndex),
    };
  }

  /// Locates the first point whose input is greater than [input].
  int _findUpperIndex(double input) {
    int lower = 1;
    int upper = _points.length - 1;
    while (lower < upper) {
      final int middle = (lower + upper) ~/ 2;
      if (_points[middle].input > input) {
        upper = middle;
      } else {
        lower = middle + 1;
      }
    }
    return lower;
  }

  /// Linearly interpolates between the two surrounding point indices.
  double _evaluateLinear(double input, int lowerIndex, int upperIndex) {
    final AcvPoint lower = _points[lowerIndex];
    final AcvPoint upper = _points[upperIndex];
    final double ratio = (input - lower.input) / (upper.input - lower.input);
    return lower.output + ratio * (upper.output - lower.output);
  }

  /// Evaluates the natural cubic segment between two surrounding points.
  double _evaluateNaturalCubic(double input, int lowerIndex, int upperIndex) {
    final AcvPoint lower = _points[lowerIndex];
    final AcvPoint upper = _points[upperIndex];
    final double width = (upper.input - lower.input).toDouble();
    final double lowerWeight = (upper.input - input) / width;
    final double upperWeight = (input - lower.input) / width;
    final List<double> derivatives = _secondDerivatives ??= _calculateSecondDerivatives();
    return lowerWeight * lower.output +
        upperWeight * upper.output +
        ((lowerWeight * lowerWeight * lowerWeight - lowerWeight) * derivatives[lowerIndex] + (upperWeight * upperWeight * upperWeight - upperWeight) * derivatives[upperIndex]) * width * width / 6;
  }

  /// Calculates natural-spline second derivatives for every control point.
  List<double> _calculateSecondDerivatives() {
    final int count = _points.length;
    final List<double> derivatives = List<double>.filled(count, 0);
    if (count <= 2) {
      return derivatives;
    }
    final List<double> temporary = List<double>.filled(count - 1, 0);
    for (int index = 1; index < count - 1; index++) {
      final double previousWidth = (_points[index].input - _points[index - 1].input).toDouble();
      final double nextWidth = (_points[index + 1].input - _points[index].input).toDouble();
      final double totalWidth = previousWidth + nextWidth;
      final double ratio = previousWidth / totalWidth;
      final double denominator = ratio * derivatives[index - 1] + 2;
      derivatives[index] = (ratio - 1) / denominator;
      final double slopeDifference = (_points[index + 1].output - _points[index].output) / nextWidth - (_points[index].output - _points[index - 1].output) / previousWidth;
      temporary[index] = (6 * slopeDifference / totalWidth - ratio * temporary[index - 1]) / denominator;
    }
    for (int index = count - 2; index >= 0; index--) {
      derivatives[index] = derivatives[index] * derivatives[index + 1] + temporary[index];
    }
    return derivatives;
  }
}
