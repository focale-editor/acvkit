import 'dart:convert';
import 'dart:typed_data';

import 'package:acvkit/src/model/acv_curve.dart';
import 'package:acvkit/src/model/acv_file.dart';
import 'package:acvkit/src/model/acv_options.dart';
import 'package:pscore/pscore.dart';

/// Encodes immutable ACV documents into Adobe Photoshop curve files.
///
/// The configured instance is a one-shot [Converter] for complete in-memory
/// files. Use [encode] when conversion options are supplied per call.
final class AcvEncoder extends Converter<AcvFile, List<int>> {
  /// Options applied by [convert].
  final AcvEncodeOptions options;

  /// Creates a reusable encoder with fixed [options].
  const AcvEncoder({
    this.options = const AcvEncodeOptions(),
  });

  @override
  Uint8List convert(AcvFile input) => encode(input, options: options);

  /// First published ACV container version.
  static const int _legacyVersion = 1;

  /// Current published ACV container version.
  static const int _currentVersion = 4;

  /// Published maximum number of curves or points in one curve.
  static const int _officialMaximumCount = 19;

  /// Encodes [file] into a new big-endian ACV byte buffer.
  static Uint8List encode(
    AcvFile file, {
    AcvEncodeOptions options = const AcvEncodeOptions(),
  }) {
    _validateRepresentable(file, options);
    if (options.mode == AcvEncodeMode.strict) {
      _validateOfficial(file, options);
    }
    final PsBinaryWriter writer = PsBinaryWriter()
      ..writeUint16(file.version)
      ..writeUint16(file.headerValue);
    for (final AcvCurve curve in file.primaryCurves) {
      _writeCurve(writer, curve, includeChannelIndex: false);
    }
    final AcvSupplementalSection? supplementalSection = file.supplementalSection;
    if (options.includeSupplementalSection && supplementalSection != null) {
      _writeSupplemental(writer, supplementalSection);
    }
    if (options.includeTrailingData) {
      writer.writeBytes(file.trailingData);
    }
    return writer.takeBytes();
  }

  /// Writes one version 1 channel-indexed supplemental section.
  static void _writeSupplemental(
    PsBinaryWriter writer,
    AcvSupplementalSection section,
  ) {
    writer
      ..writeString(section.marker)
      ..writeUint16(section.version)
      ..writeUint32(section.declaredCurveCount);
    for (final AcvCurve curve in section.curves) {
      _writeCurve(writer, curve, includeChannelIndex: true);
    }
  }

  /// Writes one section-specific curve entry.
  static void _writeCurve(
    PsBinaryWriter writer,
    AcvCurve curve, {
    required bool includeChannelIndex,
  }) {
    if (includeChannelIndex) {
      writer.writeUint16(curve.channelIndex);
    }
    writer.writeUint16(curve.declaredPointCount);
    PsToneCurveCodec.writePoints(writer, curve.points);
  }

  /// Checks that every emitted integer and marker fits its binary field.
  static void _validateRepresentable(
    AcvFile file,
    AcvEncodeOptions options,
  ) {
    _requireUnsigned(file.version, 16, 'ACV version');
    _requireUnsigned(file.headerValue, 16, 'ACV header value');
    if (file.version != _legacyVersion && file.version != _currentVersion) {
      if (file.primaryCurves.isNotEmpty) {
        throw const AcvWriteException(
          message: 'Curves cannot be encoded for an unknown ACV container version',
        );
      }
      if (options.includeSupplementalSection && file.supplementalSection != null) {
        throw const AcvWriteException(
          message: 'A supplemental section cannot be encoded for an unknown ACV container version',
        );
      }
    }
    if (file.version == _currentVersion && options.includeSupplementalSection && file.supplementalSection != null) {
      throw const AcvWriteException(
        message: 'Only version 1 ACV files can contain a supplemental section',
      );
    }
    for (final AcvCurve curve in file.primaryCurves) {
      _validateRepresentableCurve(curve, includesChannelIndex: false);
    }
    final AcvSupplementalSection? section = file.supplementalSection;
    if (options.includeSupplementalSection && section != null) {
      if (section.marker.length != 4 || section.marker.codeUnits.any((codeUnit) => codeUnit > 0xff)) {
        throw const AcvWriteException(
          message: 'The supplemental marker must contain exactly four Latin-1 bytes',
        );
      }
      _requireUnsigned(section.version, 16, 'Supplemental version');
      _requireUnsigned(section.declaredCurveCount, 32, 'Supplemental curve count');
      for (final AcvCurve curve in section.curves) {
        _validateRepresentableCurve(curve, includesChannelIndex: true);
      }
    }
    if (options.includeTrailingData && file.trailingData.length != file.trailingByteCount) {
      throw AcvWriteException(
        message: 'Only ${file.trailingData.length} of ${file.trailingByteCount} trailing bytes were preserved; disable trailing-data output or decode with preservation enabled',
      );
    }
  }

  /// Checks that one curve entry fits unsigned ACV numeric fields.
  static void _validateRepresentableCurve(
    AcvCurve curve, {
    required bool includesChannelIndex,
  }) {
    if (includesChannelIndex) {
      _requireUnsigned(curve.channelIndex, 16, 'Curve channel index');
    }
    _requireUnsigned(curve.declaredPointCount, 16, 'Curve point count');
    if (curve.points.length > 0xffff) {
      throw AcvWriteException(
        message: 'Curve contains ${curve.points.length} points, exceeding the 16-bit ACV capacity',
      );
    }
    for (final AcvPoint point in curve.points) {
      _requireUnsigned(point.output, 16, 'Curve output coordinate');
      _requireUnsigned(point.input, 16, 'Curve input coordinate');
    }
  }

  /// Applies all constraints from the published ACV format description.
  static void _validateOfficial(
    AcvFile file,
    AcvEncodeOptions options,
  ) {
    if (file.version != _legacyVersion && file.version != _currentVersion) {
      throw AcvWriteException(
        message: 'ACV container version ${file.version} is not supported by the published format',
      );
    }
    if (options.includeTrailingData && file.trailingData.isNotEmpty) {
      throw const AcvWriteException(
        message: 'Strict ACV output cannot contain unrecognized trailing bytes',
      );
    }
    switch (file.version) {
      case _legacyVersion:
        _validateOfficialLegacy(file);
      case _currentVersion:
        _validateOfficialCurrent(file);
    }
    file.primaryCurves.forEach(_validateOfficialCurve);
    final AcvSupplementalSection? section = file.supplementalSection;
    if (options.includeSupplementalSection && section != null) {
      _validateOfficialSupplemental(section);
    }
  }

  /// Validates a version 4 count and its implied sequential channels.
  static void _validateOfficialCurrent(AcvFile file) {
    final int curveCount = file.primaryCurves.length;
    if (file.headerValue != curveCount || curveCount < 1 || curveCount > _officialMaximumCount) {
      throw const AcvWriteException(
        message: 'Version 4 requires 1 through $_officialMaximumCount primary curves and a matching header count',
      );
    }
    for (int index = 0; index < curveCount; index++) {
      if (file.primaryCurves[index].channelIndex != index) {
        throw AcvWriteException(
          message: 'Version 4 curve ${index + 1} must represent implied channel $index',
        );
      }
    }
  }

  /// Validates a version 1 bitmap against its primary curve order.
  static void _validateOfficialLegacy(AcvFile file) {
    if (file.headerValue == 0) {
      throw const AcvWriteException(
        message: 'Version 1 requires at least one selected primary channel',
      );
    }
    final List<int> channels = file.primaryChannelIndices;
    if (channels.length != file.primaryCurves.length) {
      throw const AcvWriteException(
        message: 'Version 1 primary curve count must match the channel bitmap',
      );
    }
    for (int index = 0; index < channels.length; index++) {
      if (file.primaryCurves[index].channelIndex != channels[index]) {
        throw AcvWriteException(
          message: 'Version 1 curve ${index + 1} must represent bitmap channel ${channels[index]}',
        );
      }
    }
  }

  /// Validates one curve against published point constraints.
  static void _validateOfficialCurve(AcvCurve curve) {
    if (curve.declaredPointCount != curve.points.length || curve.points.length < 2 || curve.points.length > _officialMaximumCount) {
      throw AcvWriteException(
        message: 'Channel ${curve.channelIndex} must contain 2 through $_officialMaximumCount points and a matching declared count',
      );
    }
    if (!curve.points.every((point) => point.isInOfficialRange)) {
      throw AcvWriteException(
        message: 'Channel ${curve.channelIndex} contains a coordinate outside the published 0 through 255 range',
      );
    }
    if (!curve.hasStrictlyIncreasingInputs) {
      throw AcvWriteException(
        message: 'Channel ${curve.channelIndex} input coordinates must be strictly increasing',
      );
    }
  }

  /// Validates a channel-indexed supplemental section.
  static void _validateOfficialSupplemental(AcvSupplementalSection section) {
    if (section.marker != 'Crv ' || section.version != _currentVersion) {
      throw const AcvWriteException(
        message: 'A supplemental section must use the "Crv " marker and version 4',
      );
    }
    if (section.declaredCurveCount != section.curves.length || section.curves.isEmpty || section.curves.length > _officialMaximumCount) {
      throw const AcvWriteException(
        message: 'A supplemental section requires 1 through $_officialMaximumCount curves and a matching declared count',
      );
    }
    section.curves.forEach(_validateOfficialCurve);
  }

  /// Requires [value] to fit an unsigned integer of [bits] bits.
  static void _requireUnsigned(int value, int bits, String label) {
    final int maximum = (1 << bits) - 1;
    if (value < 0 || value > maximum) {
      throw AcvWriteException(
        message: '$label value $value does not fit an unsigned $bits-bit field',
      );
    }
  }
}
