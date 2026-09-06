import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

/// Exercises authored documents, encoding validation, and curve evaluation.
void main() {
  group('AcvEncoder', () {
    test('writes and reads an authored version 4 document', () {
      final AcvFile source = AcvFile.versionFour(
        curves: [
          _editableCurve(0, const [AcvPoint(input: 0, output: 0), AcvPoint(input: 255, output: 255)]),
          _editableCurve(1, const [AcvPoint(input: 0, output: 4), AcvPoint(input: 128, output: 180), AcvPoint(input: 255, output: 252)]),
        ],
      );

      final Uint8List bytes = AcvEncoder.encode(source);
      final AcvFile decoded = AcvDecoder.decode(
        bytes,
        options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
      );

      check(decoded.version).equals(4);
      check(decoded.primaryCurves).length.equals(2);
      check(decoded.redCurve?.points).isNotNull().deepEquals(source.redCurve!.points);
      check(decoded.isOfficial).isTrue();
    });

    test('sorts authored version 1 primary channels into bitmap order', () {
      final AcvFile source = AcvFile.versionOne(
        primaryCurves: [_identityCurve(3), _identityCurve(0)],
        supplementalCurves: [_identityCurve(2), _identityCurve(0)],
      );

      final Uint8List bytes = AcvEncoder.encode(source);
      final AcvFile decoded = AcvDecoder.decode(
        bytes,
        options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
      );

      check(source.headerValue).equals(9);
      check(decoded.primaryCurves.map((curve) => curve.channelIndex)).deepEquals([0, 3]);
      check(decoded.supplementalSection?.curves.map((curve) => curve.channelIndex)).isNotNull().deepEquals([2, 0]);
      check(decoded.isOfficial).isTrue();
    });

    test('strict mode rejects nonstandard curves that permissive mode writes', () {
      final AcvCurve curve = _editableCurve(
        0,
        const [AcvPoint(input: 10, output: 300)],
      );
      final AcvFile file = AcvFile.versionFour(curves: [curve]);

      check(() => AcvEncoder.encode(file)).throws<AcvWriteException>();
      final Uint8List bytes = AcvEncoder.encode(
        file,
        options: const AcvEncodeOptions(mode: AcvEncodeMode.permissive),
      );
      final AcvFile decoded = AcvDecoder.decode(bytes);
      check(decoded.primaryCurves.single.points.single.output).equals(300);
      check(decoded.warnings).length.equals(2);
    });

    test('strict mode rejects mismatched implied version 4 channels', () {
      final AcvFile wrongVersionFourChannels = AcvFile.versionFour(
        curves: [_identityCurve(2)],
      );

      check(() => AcvEncoder.encode(wrongVersionFourChannels)).throws<AcvWriteException>();
    });

    test('preserves duplicate and full-width supplemental channel indices', () {
      final AcvSupplementalSection duplicateSection = AcvSupplementalSection.editable(
        curves: [_identityCurve(65535), _identityCurve(65535)],
      );
      final AcvFile duplicateSupplementalChannels = AcvFile(
        version: 1,
        headerValue: 1,
        primaryCurves: [_identityCurve(0)],
        supplementalSection: duplicateSection,
        trailingData: Uint8List(0),
        trailingByteCount: 0,
        sourceData: null,
        warnings: const [],
      );

      final Uint8List bytes = AcvEncoder.encode(duplicateSupplementalChannels);
      final AcvFile decoded = AcvDecoder.decode(
        bytes,
        options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
      );

      check(decoded.supplementalSection?.curves).isNotNull().length.equals(2);
      check(decoded.supplementalSection?.curveForChannel(65535)).identicalTo(decoded.supplementalSection?.curves.last);
      check(decoded.warnings).isEmpty();
    });
  });

  group('AcvCurve', () {
    test('evaluates identity, linear, and natural cubic interpolation', () {
      final AcvCurve identity = _identityCurve(0);
      final AcvCurve hill = _editableCurve(
        0,
        const [AcvPoint(input: 0, output: 0), AcvPoint(input: 128, output: 255), AcvPoint(input: 255, output: 0)],
      );

      check(identity.evaluate(63.75)).isCloseTo(63.75, 0.000001);
      check(identity.evaluateNormalized(0.25)).isCloseTo(0.25, 0.000001);
      check(hill.evaluate(64, interpolation: AcvInterpolation.linear)).isCloseTo(127.5, 0.000001);
      check(hill.evaluate(64)).isGreaterThan(127.5);
      check(hill.evaluate(-10)).equals(0);
      check(hill.evaluate(400)).equals(0);
    });

    test('builds deterministic floating-point and 8-bit lookup tables', () {
      final AcvCurve identity = _identityCurve(0);

      final Float64List floatingPoint = identity.toLookupTable(size: 3);
      final Uint8List bytes = identity.toUint8LookupTable(size: 3);

      check(floatingPoint).deepEquals([0, 127.5, 255]);
      check(bytes).deepEquals([0, 128, 255]);
      check(() => identity.toLookupTable(size: 0)).throws<ArgumentError>();
    });

    test('creates identities and clears stale metadata when edited', () {
      final AcvCurve source = AcvCurve(
        index: 3,
        channelIndex: 3,
        section: AcvCurveSection.supplemental,
        sourceOffset: 40,
        declaredPointCount: 2,
        points: const [AcvPoint(input: 0, output: 0), AcvPoint(input: 255, output: 255)],
        recordData: Uint8List.fromList([0, 3]),
      );

      final AcvCurve edited = source.copyWith(
        points: const [AcvPoint(input: 0, output: 8), AcvPoint(input: 255, output: 240)],
      );

      check(AcvCurve.identity(channelIndex: 0).isIdentity).isTrue();
      check(edited.index).equals(3);
      check(edited.channelIndex).equals(3);
      check(edited.section).equals(AcvCurveSection.supplemental);
      check(edited.sourceOffset).equals(-1);
      check(edited.recordData).isNull();
      check(edited.points.first.output).equals(8);
    });
  });

  group('AcvFile channel layouts', () {
    test('maps the published Indexed Color table and alpha positions', () {
      final AcvFile file = AcvFile.versionFour(
        curves: [
          for (int index = 0; index < 19; index++) AcvCurve.identity(channelIndex: index),
        ],
      );

      check(file.indexedColorTableCurve(AcvIndexedColorComponent.red)).identicalTo(file.primaryCurves[1]);
      check(file.indexedColorTableCurve(AcvIndexedColorComponent.green)).identicalTo(file.primaryCurves[2]);
      check(file.indexedColorTableCurve(AcvIndexedColorComponent.blue)).identicalTo(file.primaryCurves[3]);
      check(file.indexedColorAlphaCurve(2)).identicalTo(file.primaryCurves[4]);
      check(file.indexedColorAlphaCurve(16)).identicalTo(file.primaryCurves[18]);
      check(() => file.indexedColorAlphaCurve(1)).throws<RangeError>();
    });
  });
}

/// Creates an editable curve for one Photoshop [channelIndex].
AcvCurve _editableCurve(int channelIndex, List<AcvPoint> points) => AcvCurve.editable(
  channelIndex: channelIndex,
  points: points,
);

/// Creates a two-point identity curve for one Photoshop [channelIndex].
AcvCurve _identityCurve(int channelIndex) => _editableCurve(
  channelIndex,
  const [AcvPoint(input: 0, output: 0), AcvPoint(input: 255, output: 255)],
);
