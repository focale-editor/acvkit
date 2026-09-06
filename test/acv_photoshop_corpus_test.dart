import 'dart:io';
import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

/// Validates locally supplied Photoshop fixtures when the ignored corpus exists.
void main() {
  test('strictly decodes and reconstructs every local ACV example', () {
    final Directory directory = Directory('ACV_EXAMPLES');
    if (!directory.existsSync()) {
      return;
    }
    final List<File> files = directory.listSync(recursive: true).whereType<File>().where((file) => file.path.toLowerCase().endsWith('.acv')).toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    check(files).isNotEmpty();

    for (final File file in files) {
      final Uint8List bytes = file.readAsBytesSync();
      final AcvFile decoded = AcvDecoder.decode(
        bytes,
        options: const AcvDecodeOptions(mode: AcvDecodeMode.strict),
      );
      final Uint8List encoded = AcvEncoder.encode(decoded);

      check(decoded.isOfficial).isTrue();
      check(encoded).deepEquals(bytes);
    }
  });
}
