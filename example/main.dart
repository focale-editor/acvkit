import 'dart:io';
import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';

/// Reads one ACV file and prints its channels and representative values.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run example/main.dart <curves.acv>');
    exitCode = 64;
    return;
  }

  try {
    final Uint8List bytes = await File(arguments.single).readAsBytes();
    final AcvFile file = AcvDecoder.decode(bytes);
    stdout.writeln(
      'ACV version ${file.version}: ${file.primaryCurves.length}/${file.declaredPrimaryCurveCount} primary curves, '
      '${file.supplementalSection?.curves.length ?? 0} supplemental curves',
    );
    for (final AcvCurve curve in file.effectiveCurves) {
      stdout.writeln(
        'channel ${curve.channelIndex}: ${curve.points.length} points, '
        'midpoint ${curve.evaluate(127.5).toStringAsFixed(2)}',
      );
    }
    file.warnings.forEach(stderr.writeln);
  } on AcvFormatException catch (error) {
    stderr.writeln(error);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 66;
  }
}
