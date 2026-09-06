import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

import 'support/acv_fixture_builder.dart';

/// Exercises both ACV layouts, compatibility recovery, and safety limits.
void main() {
  group('AcvDecoder', () {
    test('decodes version 4 metadata, points, and exact records', () {
      final Uint8List bytes = AcvFixtureBuilder.versionFour(
        curves: [
          _curve(0, const [AcvPoint(input: 0, output: 0), AcvPoint(input: 255, output: 255)]),
          _curve(1, const [AcvPoint(input: 0, output: 12), AcvPoint(input: 128, output: 192), AcvPoint(input: 255, output: 250)]),
        ],
      );

      final AcvFile file = AcvDecoder.decode(
        bytes,
        options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
      );
      final AcvCurve red = file.primaryCurves.last;

      check(file.version).equals(4);
      check(file.headerValue).equals(2);
      check(file.declaredPrimaryCurveCount).equals(2);
      check(file.primaryChannelIndices).deepEquals([0, 1]);
      check(file.isComplete).isTrue();
      check(file.isOfficial).isTrue();
      check(file.warnings).isEmpty();
      check(file.sourceData).isNotNull().deepEquals(bytes);
      check(file.compositeCurve?.isIdentity).isNotNull().isTrue();
      check(file.redCurve).identicalTo(red);
      check(file.greenCurve).isNull();
      check(red.index).equals(1);
      check(red.channelIndex).equals(1);
      check(red.section).equals(AcvCurveSection.primary);
      check(red.sourceOffset).equals(14);
      check(red.declaredPointCount).equals(3);
      check(red.points[1]).equals(const AcvPoint(input: 128, output: 192));
      check(red.recordData).isNotNull().deepEquals(bytes.sublist(14));
      check(AcvEncoder.encode(file)).deepEquals(bytes);
    });

    test('decodes sparse version 1 channels and explicit supplemental data', () {
      final Uint8List bytes = AcvFixtureBuilder.versionOne(
        channelBitmap: 0x0009,
        primaryCurves: [_identity(0), _identity(3)],
        supplementalCurves: [
          _identity(0),
          _curve(1, const [AcvPoint(input: 0, output: 10), AcvPoint(input: 255, output: 240)]),
          _identity(2),
          _curve(3, const [AcvPoint(input: 0, output: 30), AcvPoint(input: 255, output: 220)]),
        ],
      );

      final AcvFile file = AcvDecoder.decode(
        bytes,
        options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
      );
      final AcvSupplementalSection section = file.supplementalSection!;

      check(file.version).equals(1);
      check(file.primaryChannelIndices).deepEquals([0, 3]);
      check(file.primaryCurves.map((curve) => curve.channelIndex)).deepEquals([0, 3]);
      check(section.marker).equals('Crv ');
      check(section.version).equals(4);
      check(section.declaredCurveCount).equals(4);
      check(section.isComplete).isTrue();
      check(section.curves.map((curve) => curve.channelIndex)).deepEquals([0, 1, 2, 3]);
      check(section.curves.first.recordData?.length).equals(12);
      check(file.effectiveCurves).identicalTo(section.curves);
      check(file.redCurve?.points.first.output).equals(10);
      check(file.blueCurve?.points.last.output).equals(220);
      check(file.isOfficial).isTrue();
      check(AcvEncoder.encode(file)).deepEquals(bytes);
    });

    test('reports nonstandard coordinates and ordering without changing them', () {
      final Uint8List bytes = AcvFixtureBuilder.versionFour(
        curves: [
          _curve(0, const [AcvPoint(input: 100, output: 400), AcvPoint(input: 50, output: 20)]),
        ],
      );

      final AcvFile tolerant = AcvDecoder.decode(bytes);

      check(tolerant.primaryCurves.single.points.first.output).equals(400);
      check(tolerant.primaryCurves.single.hasStrictlyIncreasingInputs).isFalse();
      check(tolerant.warnings).length.equals(2);
      check(() => tolerant.primaryCurves.single.evaluate(75)).throws<StateError>();
      check(
        () => AcvDecoder.decode(
          bytes,
          options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
        ),
      ).throws<AcvFormatException>();
      check(
        AcvEncoder.encode(
          tolerant,
          options: const AcvEncodeOptions(mode: AcvEncodeMode.permissive),
        ),
      ).deepEquals(bytes);
    });

    test('returns complete earlier curves when a later record is truncated', () {
      final Uint8List bytes = AcvFixtureBuilder.versionFour(
        declaredCurveCount: 2,
        curves: [
          _identity(0),
          AcvTestCurve(
            channelIndex: 1,
            declaredPointCount: 2,
            points: const [AcvPoint(input: 0, output: 0)],
          ),
        ],
      );

      final AcvFile file = AcvDecoder.decode(bytes);

      check(file.primaryCurves).length.equals(1);
      check(file.isComplete).isFalse();
      check(file.trailingByteCount).equals(6);
      check(file.trailingData).deepEquals(bytes.sublist(14));
      check(file.warnings).length.equals(1);
      check(
        AcvEncoder.encode(
          file,
          options: const AcvEncodeOptions(mode: AcvEncodeMode.permissive),
        ),
      ).deepEquals(bytes);
      check(
        () => AcvDecoder.decode(
          bytes,
          options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
        ),
      ).throws<AcvFormatException>();
    });

    test('preserves unsupported versions as opaque payloads in tolerant mode', () {
      final Uint8List bytes = AcvFixtureBuilder.unsupported(
        version: 7,
        headerValue: 42,
        payload: const [1, 2, 3, 4],
      );

      final AcvFile file = AcvDecoder.decode(bytes);

      check(file.hasSupportedVersion).isFalse();
      check(file.primaryCurves).isEmpty();
      check(file.trailingData).deepEquals([1, 2, 3, 4]);
      check(file.warnings).length.equals(1);
      check(
        AcvEncoder.encode(
          file,
          options: const AcvEncodeOptions(mode: AcvEncodeMode.permissive),
        ),
      ).deepEquals(bytes);
      check(
        () => AcvDecoder.decode(
          bytes,
          options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
        ),
      ).throws<AcvFormatException>();
    });

    test('preserves unknown and incomplete supplemental sections opaquely', () {
      final Uint8List unknownVersion = AcvFixtureBuilder.versionOne(
        channelBitmap: 1,
        primaryCurves: [_identity(0)],
        supplementalCurves: const [],
        supplementalVersion: 9,
      );
      final Uint8List truncated = Uint8List.fromList(unknownVersion.sublist(0, unknownVersion.length - 3));

      for (final Uint8List bytes in [unknownVersion, truncated]) {
        final AcvFile file = AcvDecoder.decode(bytes);

        check(file.supplementalSection).isNull();
        check(file.trailingByteCount).isGreaterThan(0);
        check(file.warnings).length.equals(1);
        check(
          AcvEncoder.encode(
            file,
            options: const AcvEncodeOptions(mode: AcvEncodeMode.permissive),
          ),
        ).deepEquals(bytes);
      }
    });

    test('can omit all redundant source and recovery byte copies', () {
      final Uint8List bytes = AcvFixtureBuilder.versionFour(
        curves: [_identity(0)],
        trailingData: const [8, 9],
      );

      final AcvFile file = AcvDecoder.decode(
        bytes,
        options: const AcvDecodeOptions(
          preserveCurveData: false,
          preserveSourceData: false,
          preserveTrailingData: false,
        ),
      );

      check(file.primaryCurves.single.recordData).isNull();
      check(file.sourceData).isNull();
      check(file.trailingData).isEmpty();
      check(file.trailingByteCount).equals(2);
      check(
        () => AcvEncoder.encode(
          file,
          options: const AcvEncodeOptions(mode: AcvEncodeMode.permissive),
        ),
      ).throws<AcvWriteException>();
      check(
        AcvEncoder.encode(
          file,
          options: const AcvEncodeOptions(
            mode: AcvEncodeMode.permissive,
            includeTrailingData: false,
          ),
        ),
      ).deepEquals(bytes.sublist(0, bytes.length - 2));
    });

    test('enforces file, curve, per-curve point, and aggregate limits', () {
      final Uint8List bytes = AcvFixtureBuilder.versionFour(
        curves: [_identity(0), _identity(1)],
      );

      check(
        () => AcvDecoder.decode(
          bytes,
          options: const AcvDecodeOptions(maxFileBytes: 10),
        ),
      ).throws<AcvFormatException>();
      check(
        () => AcvDecoder.decode(
          bytes,
          options: const AcvDecodeOptions(maxCurvesPerSection: 1),
        ),
      ).throws<AcvFormatException>();
      check(
        () => AcvDecoder.decode(
          bytes,
          options: const AcvDecodeOptions(maxPointsPerCurve: 1),
        ),
      ).throws<AcvFormatException>();
      check(
        () => AcvDecoder.decode(
          bytes,
          options: const AcvDecodeOptions(maxTotalPoints: 3),
        ),
      ).throws<AcvFormatException>();
    });

    test('rejects incomplete fixed headers in every mode', () {
      final Uint8List bytes = Uint8List.fromList([0, 4, 0]);

      check(() => AcvDecoder.decode(bytes)).throws<AcvFormatException>();
    });
  });
}

/// Creates a synthetic curve with the requested channel and [points].
AcvTestCurve _curve(int channelIndex, List<AcvPoint> points) => AcvTestCurve(
  channelIndex: channelIndex,
  points: points,
);

/// Creates the published two-point identity curve for [channelIndex].
AcvTestCurve _identity(int channelIndex) => _curve(
  channelIndex,
  const [AcvPoint(input: 0, output: 0), AcvPoint(input: 255, output: 255)],
);
