import 'dart:io';
import 'dart:typed_data';

import 'package:acvkit/acvkit.dart';

/// Inspects ACV files and optionally verifies their byte-exact reconstruction.
void main(List<String> arguments) {
  final bool strict = arguments.contains('--strict');
  final bool roundTrip = arguments.contains('--round-trip');
  final bool summaryOnly = arguments.contains('--summary-only');
  final List<String> paths = [
    for (final String argument in arguments)
      if (!argument.startsWith('--')) argument,
  ];
  if (paths.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/inspect_acv.dart '
      '[--strict] [--round-trip] [--summary-only] '
      '<file-or-directory> [...]',
    );
    exitCode = 64;
    return;
  }

  final List<File> files = _acvFiles(paths);
  if (files.isEmpty) {
    stderr.writeln('No ACV files found.');
    exitCode = 66;
    return;
  }
  for (final File file in files) {
    _inspect(
      file,
      strict: strict,
      roundTrip: roundTrip,
      summaryOnly: summaryOnly,
    );
  }
}

/// Returns ACV files contained in the requested files and directories.
List<File> _acvFiles(List<String> paths) {
  final List<File> files = [];
  for (final String path in paths) {
    switch (FileSystemEntity.typeSync(path)) {
      case FileSystemEntityType.file:
        if (_isAcvPath(path)) {
          files.add(File(path));
        }
      case FileSystemEntityType.directory:
        files.addAll(
          Directory(path).listSync(recursive: true).whereType<File>().where((file) => _isAcvPath(file.path)),
        );
      case FileSystemEntityType.link:
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        break;
    }
  }
  files.sort((left, right) => left.path.compareTo(right.path));
  return files;
}

/// Decodes and prints one concise structural report for [file].
void _inspect(
  File file, {
  required bool strict,
  required bool roundTrip,
  required bool summaryOnly,
}) {
  try {
    final Uint8List bytes = file.readAsBytesSync();
    final AcvFile decoded = AcvDecoder.decode(
      bytes,
      options: AcvDecodeOptions(
        mode: strict ? AcvDecodeMode.strict : AcvDecodeMode.tolerant,
        preserveCurveData: false,
        preserveSourceData: false,
      ),
    );
    final AcvSupplementalSection? supplemental = decoded.supplementalSection;
    final String reconstruction = roundTrip ? ', reconstruction ${_reconstructionLabel(decoded, bytes)}' : '';
    stdout.writeln(
      '${file.path}: version ${decoded.version}, '
      '${decoded.primaryCurves.length}/${decoded.declaredPrimaryCurveCount} primary curves, '
      '${supplemental?.curves.length ?? 0}/${supplemental?.declaredCurveCount ?? 0} supplemental curves, '
      '${decoded.trailingByteCount} trailing bytes, ${decoded.warnings.length} warnings$reconstruction',
    );
    if (!summaryOnly) {
      decoded.primaryCurves.forEach(_printCurve);
      if (supplemental != null) {
        supplemental.curves.forEach(_printCurve);
      }
    }
    for (final AcvWarning warning in decoded.warnings) {
      stdout.writeln('  warning: $warning');
    }
  } on Object catch (error) {
    stderr.writeln('${file.path}: $error');
    exitCode = 1;
  }
}

/// Prints one decoded curve and its endpoint coordinates.
void _printCurve(AcvCurve curve) {
  final AcvPoint? first = curve.points.firstOrNull;
  final AcvPoint? last = curve.points.lastOrNull;
  stdout.writeln(
    '  ${curve.section.name} curve ${curve.index + 1}, channel ${curve.channelIndex}: '
    '${curve.points.length}/${curve.declaredPointCount} points, '
    '${first ?? '<empty>'} to ${last ?? '<empty>'}',
  );
}

/// Reports whether permissive encoding recreates [source] exactly.
String _reconstructionLabel(AcvFile file, Uint8List source) {
  final Uint8List encoded = AcvEncoder.encode(
    file,
    options: const AcvEncodeOptions(mode: AcvEncodeMode.permissive),
  );
  if (encoded.length != source.length) {
    return 'differs (${encoded.length} versus ${source.length} bytes)';
  }
  for (int index = 0; index < source.length; index++) {
    if (encoded[index] != source[index]) {
      return 'differs at byte $index';
    }
  }
  return 'exact';
}

/// Whether [path] has the case-insensitive ACV extension.
bool _isAcvPath(String path) => path.toLowerCase().endsWith('.acv');
