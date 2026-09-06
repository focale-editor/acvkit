import 'dart:math';
import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

/// Exercises deterministic property cases, malformed bytes, and immutability.
void main() {
  test('round-trips varied valid version 4 and version 1 documents', () {
    final Random random = Random(0x0ac5c0de);
    for (int iteration = 0; iteration < 100; iteration++) {
      final AcvFile versionFour = AcvFile.versionFour(
        curves: [
          for (int channelIndex = 0; channelIndex < 1 + random.nextInt(5); channelIndex++) _randomCurve(random, channelIndex),
        ],
      );
      _checkStrictRoundTrip(versionFour);

      final List<int> primaryChannels = _randomChannels(random, maximumExclusive: 16);
      final List<int> supplementalChannels = _randomChannels(random, maximumExclusive: 19);
      final AcvFile versionOne = AcvFile.versionOne(
        primaryCurves: [
          for (final int channelIndex in primaryChannels) _randomCurve(random, channelIndex),
        ],
        supplementalCurves: [
          for (final int channelIndex in supplementalChannels) _randomCurve(random, channelIndex),
        ],
      );
      _checkStrictRoundTrip(versionOne);
    }
  });

  test('never leaks low-level failures for deterministic malformed input', () {
    final Random random = Random(0x0badac7);
    for (int iteration = 0; iteration < 2000; iteration++) {
      final int length = random.nextInt(129);
      final Uint8List bytes = Uint8List.fromList([
        for (int index = 0; index < length; index++) random.nextInt(256),
      ]);
      if (length >= 2 && iteration.isEven) {
        bytes[0] = 0;
        bytes[1] = iteration % 4 == 0 ? 1 : 4;
      }
      try {
        AcvDecoder.decode(
          bytes,
          options: const AcvDecodeOptions(
            maxFileBytes: 256,
            maxCurvesPerSection: 64,
            maxPointsPerCurve: 64,
            maxTotalPoints: 256,
            preserveCurveData: false,
            preserveSourceData: false,
            preserveTrailingData: false,
          ),
        );
      } on AcvFormatException {
        continue;
      }
    }
  });

  test('defensively copies caller-owned model and source buffers', () {
    final List<AcvPoint> points = [
      const AcvPoint(input: 0, output: 0),
      const AcvPoint(input: 255, output: 255),
    ];
    final Uint8List recordData = Uint8List.fromList([0, 2]);
    final AcvCurve curve = AcvCurve(
      index: 0,
      channelIndex: 0,
      section: AcvCurveSection.primary,
      sourceOffset: 4,
      declaredPointCount: 2,
      points: points,
      recordData: recordData,
    );
    points.clear();
    recordData[0] = 9;

    check(curve.points).length.equals(2);
    check(curve.recordData).isNotNull().deepEquals([0, 2]);
    check(() => curve.points.add(const AcvPoint(input: 1, output: 1))).throws<UnsupportedError>();

    final Uint8List bytes = AcvEncoder.encode(AcvFile.versionFour(curves: [curve]));
    final AcvFile decoded = AcvDecoder.decode(bytes);
    bytes.fillRange(0, bytes.length, 0xff);

    check(decoded.version).equals(4);
    check(decoded.sourceData?.first).equals(0);
    check(decoded.primaryCurves.single.points.last.output).equals(255);
  });
}

/// Builds one valid curve with deterministic random intermediate points.
AcvCurve _randomCurve(Random random, int channelIndex) {
  final int pointCount = 2 + random.nextInt(18);
  final Set<int> inputSet = {0, 255};
  while (inputSet.length < pointCount) {
    inputSet.add(random.nextInt(256));
  }
  final List<int> inputs = inputSet.toList()..sort();
  return AcvCurve.editable(
    channelIndex: channelIndex,
    points: [
      for (final int input in inputs)
        AcvPoint(
          input: input,
          output: random.nextInt(256),
        ),
    ],
  );
}

/// Selects a non-empty unique subset of channel indices.
List<int> _randomChannels(Random random, {required int maximumExclusive}) {
  final List<int> candidates = List<int>.generate(maximumExclusive, (index) => index)..shuffle(random);
  return candidates.take(1 + random.nextInt(5)).toList();
}

/// Verifies strict decode and byte-stable re-encoding for [source].
void _checkStrictRoundTrip(AcvFile source) {
  final Uint8List encoded = AcvEncoder.encode(source);
  final AcvFile decoded = AcvDecoder.decode(
    encoded,
    options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
  );

  check(decoded.isOfficial).isTrue();
  check(AcvEncoder.encode(decoded)).deepEquals(encoded);
}
