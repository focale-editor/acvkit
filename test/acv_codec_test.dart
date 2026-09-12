import 'dart:convert';
import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

/// Exercises the reusable `dart:convert` ACV interface.
void main() {
  group('AcvCodec', () {
    test('converts complete files and composes with base64', () {
      const AcvCodec codec = AcvCodec(
        decodeOptions: AcvDecodeOptions(mode: AcvDecodeMode.strict),
        encodeOptions: AcvEncodeOptions(mode: AcvEncodeMode.strict),
      );
      final AcvFile file = AcvFile.versionFour(
        curves: <AcvCurve>[AcvCurve.identity(channelIndex: 0)],
      );

      final Uint8List encoded = codec.encode(file);
      final AcvFile decoded = codec.decode(encoded.toList(growable: false));
      final Codec<AcvFile, String> base64Codec = codec.fuse(base64);
      final AcvFile decodedBase64 = base64Codec.decode(base64Codec.encode(file));

      check(decoded.primaryCurves.single.points).deepEquals(file.primaryCurves.single.points);
      check(decodedBase64.version).equals(file.version);
      check(codec.decoder.options.mode).equals(AcvDecodeMode.strict);
      check(codec.encoder.options.mode).equals(AcvEncodeMode.strict);
    });
  });
}
