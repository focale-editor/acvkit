import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';

/// Curve description used to assemble precise ACV test fixtures.
final class AcvTestCurve {
  /// Explicit channel index used by version 1 supplemental records.
  final int channelIndex;

  /// Point count written in the record header.
  final int declaredPointCount;

  /// Point pairs physically written after the count.
  final List<AcvPoint> points;

  /// Creates one synthetic curve record.
  AcvTestCurve({
    required this.channelIndex,
    required List<AcvPoint> points,
    int? declaredPointCount,
  }) : declaredPointCount = declaredPointCount ?? points.length,
       points = List<AcvPoint>.unmodifiable(points);
}

/// Builds small byte-exact ACV fixtures without using the production encoder.
abstract final class AcvFixtureBuilder {
  /// Builds a version 4 file with sequential primary curve records.
  static Uint8List versionFour({
    required List<AcvTestCurve> curves,
    int? declaredCurveCount,
    List<int> trailingData = const [],
  }) {
    final PsBinaryWriter writer = PsBinaryWriter()
      ..writeUint16(4)
      ..writeUint16(declaredCurveCount ?? curves.length);
    for (final AcvTestCurve curve in curves) {
      _writeCurve(writer, curve);
    }
    writer.writeBytes(trailingData);
    return writer.takeBytes();
  }

  /// Builds a version 1 file with bitmap-selected primary curves.
  static Uint8List versionOne({
    required int channelBitmap,
    required List<AcvTestCurve> primaryCurves,
    List<AcvTestCurve>? supplementalCurves,
    String supplementalMarker = 'Crv ',
    int supplementalVersion = 4,
    int? supplementalDeclaredCurveCount,
    List<int> trailingData = const [],
  }) {
    final PsBinaryWriter writer = PsBinaryWriter()
      ..writeUint16(1)
      ..writeUint16(channelBitmap);
    for (final AcvTestCurve curve in primaryCurves) {
      _writeCurve(writer, curve);
    }
    if (supplementalCurves != null) {
      writer
        ..writeString(supplementalMarker)
        ..writeUint16(supplementalVersion)
        ..writeUint32(supplementalDeclaredCurveCount ?? supplementalCurves.length);
      for (final AcvTestCurve curve in supplementalCurves) {
        writer.writeUint16(curve.channelIndex);
        _writeCurve(writer, curve);
      }
    }
    writer.writeBytes(trailingData);
    return writer.takeBytes();
  }

  /// Builds an arbitrary four-byte ACV header and payload.
  static Uint8List unsupported({
    required int version,
    required int headerValue,
    List<int> payload = const [],
  }) =>
      (PsBinaryWriter()
            ..writeUint16(version)
            ..writeUint16(headerValue)
            ..writeBytes(payload))
          .takeBytes();

  /// Writes one primary-style point-count and output/input sequence.
  static void _writeCurve(PsBinaryWriter writer, AcvTestCurve curve) {
    writer.writeUint16(curve.declaredPointCount);
    for (final AcvPoint point in curve.points) {
      writer
        ..writeUint16(point.output)
        ..writeUint16(point.input);
    }
  }
}
