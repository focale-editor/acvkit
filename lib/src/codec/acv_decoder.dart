import 'dart:typed_data';

import 'package:acvkit/src/model/acv_curve.dart';
import 'package:acvkit/src/model/acv_file.dart';
import 'package:acvkit/src/model/acv_options.dart';
import 'package:pscore/pscore.dart';

/// Decodes Adobe Photoshop ACV tone-curve files.
abstract final class AcvDecoder {
  /// First published ACV container version.
  static const int _legacyVersion = 1;

  /// Current published ACV container version.
  static const int _currentVersion = 4;

  /// Marker introducing channel-indexed data in a version 1 file.
  static const String _supplementalMarker = 'Crv ';

  /// Published version of the channel-indexed supplemental section.
  static const int _supplementalVersion = 4;

  /// Published maximum number of curves or points in one curve.
  static const int _officialMaximumCount = 19;

  /// Decodes one complete in-memory ACV [bytes] buffer.
  static AcvFile decode(
    Uint8List bytes, {
    AcvDecodeOptions options = const AcvDecodeOptions(),
  }) {
    _validateOptions(options);
    if (bytes.length > options.maxFileBytes) {
      throw AcvFormatException(
        message: 'ACV file size ${bytes.length} exceeds the configured ${options.maxFileBytes} byte limit',
        source: bytes,
        offset: 0,
      );
    }
    try {
      return _decode(bytes, options);
    } on AcvFormatException {
      rethrow;
    } on PsFormatException catch (error) {
      throw AcvFormatException(
        message: error.message,
        source: bytes,
        offset: error.offset,
      );
    } on RangeError catch (error) {
      throw AcvFormatException(
        message: 'Invalid ACV numeric range: $error',
        source: bytes,
      );
    }
  }

  /// Decodes the fixed header and version-dependent curve sections.
  static AcvFile _decode(Uint8List bytes, AcvDecodeOptions options) {
    final PsBinaryReader reader = PsBinaryReader(bytes: bytes);
    final int version = reader.readUint16();
    final int headerValue = reader.readUint16();
    final _AcvDecodeContext context = _AcvDecodeContext(
      bytes: bytes,
      options: options,
      version: version,
      headerValue: headerValue,
    );
    switch (version) {
      case _legacyVersion:
        _decodeLegacy(reader, context);
      case _currentVersion:
        _decodeCurrent(reader, context);
      default:
        context.issue(
          'ACV container version $version is not currently defined',
          0,
        );
        context.setTrailing(reader.offset);
    }
    return context.build();
  }

  /// Decodes version 4 curves whose channels are implied by source order.
  static void _decodeCurrent(
    PsBinaryReader reader,
    _AcvDecodeContext context,
  ) {
    final int curveCount = context.headerValue;
    context.ensureCurveCount(curveCount, 2);
    if (curveCount < 1 || curveCount > _officialMaximumCount) {
      context.issue(
        'Version 4 declares $curveCount curves; the published range is 1 through $_officialMaximumCount',
        2,
      );
    }
    final bool complete = _decodeCurveSequence(
      reader: reader,
      context: context,
      channels: List<int>.generate(curveCount, (index) => index),
      section: AcvCurveSection.primary,
    );
    if (complete) {
      _captureUnexpectedTrailing(reader, context);
    }
  }

  /// Decodes version 1 bitmap-selected curves and its optional extension.
  static void _decodeLegacy(
    PsBinaryReader reader,
    _AcvDecodeContext context,
  ) {
    final List<int> channels = [
      for (int index = 0; index < 16; index++)
        if (context.headerValue & (1 << index) != 0) index,
    ];
    context.ensureCurveCount(channels.length, 2);
    if (channels.isEmpty) {
      context.issue(
        'Version 1 channel bitmap does not select any primary curves',
        2,
      );
    }
    final bool complete = _decodeCurveSequence(
      reader: reader,
      context: context,
      channels: channels,
      section: AcvCurveSection.primary,
    );
    if (!complete || reader.isAtEnd) {
      return;
    }
    if (!_hasMarker(reader, _supplementalMarker)) {
      _captureUnexpectedTrailing(reader, context);
      return;
    }
    _decodeSupplemental(reader, context);
  }

  /// Decodes a `Crv ` section with explicit channel indices.
  static void _decodeSupplemental(
    PsBinaryReader reader,
    _AcvDecodeContext context,
  ) {
    final int sectionOffset = reader.offset;
    try {
      final String marker = reader.readString(4);
      final int versionOffset = reader.offset;
      final int version = reader.readUint16();
      if (version != _supplementalVersion) {
        context.issue(
          'Supplemental ACV version $version is not currently defined',
          versionOffset,
          section: AcvCurveSection.supplemental,
        );
        context.setTrailing(sectionOffset);
        return;
      }
      final int countOffset = reader.offset;
      final int curveCount = reader.readUint32();
      context.ensureCurveCount(curveCount, countOffset);
      if (curveCount < 1 || curveCount > _officialMaximumCount) {
        context.issue(
          'Supplemental section declares $curveCount curves; the published range is 1 through $_officialMaximumCount',
          countOffset,
          section: AcvCurveSection.supplemental,
        );
      }
      context.beginSupplemental(
        marker: marker,
        version: version,
        sourceOffset: sectionOffset,
        declaredCurveCount: curveCount,
      );
      final bool complete = _decodeSupplementalCurves(
        reader,
        context,
        curveCount,
      );
      if (complete) {
        _captureUnexpectedTrailing(reader, context);
      }
    } on AcvFormatException {
      rethrow;
    } on PsFormatException catch (error) {
      _recoverTruncation(
        context: context,
        recordOffset: sectionOffset,
        message: 'Supplemental section could not be decoded: ${error.message}',
        errorOffset: error.offset,
        section: AcvCurveSection.supplemental,
      );
    }
  }

  /// Decodes the declared number of explicitly indexed supplemental curves.
  static bool _decodeSupplementalCurves(
    PsBinaryReader reader,
    _AcvDecodeContext context,
    int curveCount,
  ) {
    for (int index = 0; index < curveCount; index++) {
      final int recordOffset = reader.offset;
      try {
        final int channelIndex = reader.readUint16();
        final AcvCurve curve = _decodeCurve(
          reader: reader,
          context: context,
          index: index,
          channelIndex: channelIndex,
          section: AcvCurveSection.supplemental,
          recordOffset: recordOffset,
        );
        context.supplementalCurves.add(curve);
      } on AcvFormatException {
        rethrow;
      } on PsFormatException catch (error) {
        _recoverTruncation(
          context: context,
          recordOffset: recordOffset,
          message: 'Supplemental curve ${index + 1} could not be decoded: ${error.message}',
          errorOffset: error.offset,
          curveIndex: index,
          section: AcvCurveSection.supplemental,
        );
        return false;
      }
    }
    return true;
  }

  /// Decodes curves whose channel indices have already been determined.
  static bool _decodeCurveSequence({
    required PsBinaryReader reader,
    required _AcvDecodeContext context,
    required List<int> channels,
    required AcvCurveSection section,
  }) {
    for (int index = 0; index < channels.length; index++) {
      final int recordOffset = reader.offset;
      try {
        final AcvCurve curve = _decodeCurve(
          reader: reader,
          context: context,
          index: index,
          channelIndex: channels[index],
          section: section,
          recordOffset: recordOffset,
        );
        context.primaryCurves.add(curve);
      } on AcvFormatException {
        rethrow;
      } on PsFormatException catch (error) {
        _recoverTruncation(
          context: context,
          recordOffset: recordOffset,
          message: 'Primary curve ${index + 1} could not be decoded: ${error.message}',
          errorOffset: error.offset,
          curveIndex: index,
          channelIndex: channels[index],
          section: section,
        );
        return false;
      }
    }
    return true;
  }

  /// Decodes one count-prefixed sequence of output/input point pairs.
  static AcvCurve _decodeCurve({
    required PsBinaryReader reader,
    required _AcvDecodeContext context,
    required int index,
    required int channelIndex,
    required AcvCurveSection section,
    required int recordOffset,
  }) {
    final int countOffset = reader.offset;
    final int pointCount = reader.readUint16();
    context.ensurePointCount(pointCount, countOffset);
    if (pointCount < 2 || pointCount > _officialMaximumCount) {
      context.issue(
        'Curve declares $pointCount points; the published range is 2 through $_officialMaximumCount',
        countOffset,
        curveIndex: index,
        channelIndex: channelIndex,
        section: section,
      );
    }
    final List<AcvPoint> points = [];
    bool hasOutOfRangeCoordinate = false;
    bool hasUnorderedInput = false;
    for (int pointIndex = 0; pointIndex < pointCount; pointIndex++) {
      final int output = reader.readUint16();
      final int input = reader.readUint16();
      if (output > 255 || input > 255) {
        hasOutOfRangeCoordinate = true;
      }
      if (points.isNotEmpty && input <= points.last.input) {
        hasUnorderedInput = true;
      }
      points.add(AcvPoint(input: input, output: output));
    }
    if (hasOutOfRangeCoordinate) {
      context.issue(
        'Curve contains coordinates outside the published 0 through 255 range',
        countOffset + 2,
        curveIndex: index,
        channelIndex: channelIndex,
        section: section,
      );
    }
    if (hasUnorderedInput) {
      context.issue(
        'Curve input coordinates are not strictly increasing',
        countOffset + 2,
        curveIndex: index,
        channelIndex: channelIndex,
        section: section,
      );
    }
    final int recordEnd = reader.offset;
    final Uint8List? recordData = context.options.preserveCurveData ? Uint8List.sublistView(context.bytes, recordOffset, recordEnd) : null;
    return AcvCurve(
      index: index,
      channelIndex: channelIndex,
      section: section,
      sourceOffset: recordOffset,
      declaredPointCount: pointCount,
      points: points,
      recordData: recordData,
    );
  }

  /// Handles a truncated record according to the configured decode mode.
  static void _recoverTruncation({
    required _AcvDecodeContext context,
    required int recordOffset,
    required String message,
    required int? errorOffset,
    required AcvCurveSection section,
    int? curveIndex,
    int? channelIndex,
  }) {
    if (context.options.mode == AcvDecodeMode.strict) {
      throw AcvFormatException(
        message: message,
        source: context.bytes,
        offset: errorOffset ?? recordOffset,
      );
    }
    context.warning(
      message,
      errorOffset ?? recordOffset,
      curveIndex: curveIndex,
      channelIndex: channelIndex,
      section: section,
    );
    context.setTrailing(recordOffset);
  }

  /// Preserves and reports bytes left after a complete recognized structure.
  static void _captureUnexpectedTrailing(
    PsBinaryReader reader,
    _AcvDecodeContext context,
  ) {
    if (reader.isAtEnd) {
      return;
    }
    context.issue(
      '${reader.remaining} unrecognized trailing bytes follow the ACV data',
      reader.offset,
    );
    context.setTrailing(reader.offset);
  }

  /// Whether the unread input begins with the requested ASCII [marker].
  static bool _hasMarker(PsBinaryReader reader, String marker) {
    if (reader.remaining < marker.length) {
      return false;
    }
    for (int index = 0; index < marker.length; index++) {
      if (reader.bytes[reader.offset + index] != marker.codeUnitAt(index)) {
        return false;
      }
    }
    return true;
  }

  /// Rejects nonsensical resource limits before parsing starts.
  static void _validateOptions(AcvDecodeOptions options) {
    if (options.maxFileBytes < 4) {
      throw ArgumentError.value(options.maxFileBytes, 'maxFileBytes', 'Must be at least 4');
    }
    if (options.maxCurvesPerSection <= 0) {
      throw ArgumentError.value(options.maxCurvesPerSection, 'maxCurvesPerSection', 'Must be positive');
    }
    if (options.maxPointsPerCurve <= 0) {
      throw ArgumentError.value(options.maxPointsPerCurve, 'maxPointsPerCurve', 'Must be positive');
    }
    if (options.maxTotalPoints <= 0) {
      throw ArgumentError.value(options.maxTotalPoints, 'maxTotalPoints', 'Must be positive');
    }
  }
}

/// Accumulates immutable model data and compatibility warnings during decoding.
final class _AcvDecodeContext {
  /// Complete source buffer being decoded.
  final Uint8List bytes;

  /// Limits and preservation policy for this operation.
  final AcvDecodeOptions options;

  /// Container version read from the fixed header.
  final int version;

  /// Version-dependent value read from the fixed header.
  final int headerValue;

  /// Successfully decoded primary curves.
  final List<AcvCurve> primaryCurves = [];

  /// Successfully decoded supplemental curves.
  final List<AcvCurve> supplementalCurves = [];

  /// Recoverable compatibility issues found so far.
  final List<AcvWarning> warnings = [];

  /// Parsed supplemental marker, when its header was complete.
  String? supplementalMarker;

  /// Parsed supplemental version, when its header was complete.
  int? supplementalVersion;

  /// Absolute offset of the parsed supplemental marker.
  int? supplementalOffset;

  /// Curve count declared by the parsed supplemental header.
  int? supplementalDeclaredCurveCount;

  /// Preserved uninterpreted bytes.
  Uint8List trailingData = Uint8List(0);

  /// Number of uninterpreted bytes regardless of preservation policy.
  int trailingByteCount = 0;

  /// Aggregate declared point count used to enforce a resource limit.
  int _totalPointCount = 0;

  /// Creates an empty decode accumulator for one source buffer.
  _AcvDecodeContext({
    required this.bytes,
    required this.options,
    required this.version,
    required this.headerValue,
  });

  /// Records the header of a recognized supplemental section.
  void beginSupplemental({
    required String marker,
    required int version,
    required int sourceOffset,
    required int declaredCurveCount,
  }) {
    supplementalMarker = marker;
    supplementalVersion = version;
    supplementalOffset = sourceOffset;
    supplementalDeclaredCurveCount = declaredCurveCount;
  }

  /// Enforces the configured per-section curve-count limit.
  void ensureCurveCount(int count, int offset) {
    if (count > options.maxCurvesPerSection) {
      throw AcvFormatException(
        message: 'ACV curve count $count exceeds the configured ${options.maxCurvesPerSection} per-section limit',
        source: bytes,
        offset: offset,
      );
    }
  }

  /// Enforces per-curve and aggregate point-count resource limits.
  void ensurePointCount(int count, int offset) {
    if (count > options.maxPointsPerCurve) {
      throw AcvFormatException(
        message: 'ACV point count $count exceeds the configured ${options.maxPointsPerCurve} per-curve limit',
        source: bytes,
        offset: offset,
      );
    }
    if (_totalPointCount + count > options.maxTotalPoints) {
      throw AcvFormatException(
        message: 'ACV aggregate point count exceeds the configured ${options.maxTotalPoints} limit',
        source: bytes,
        offset: offset,
      );
    }
    _totalPointCount += count;
  }

  /// Turns a compatibility issue into either an exception or a warning.
  void issue(
    String message,
    int offset, {
    int? curveIndex,
    int? channelIndex,
    AcvCurveSection? section,
  }) {
    if (options.mode == AcvDecodeMode.strict) {
      throw AcvFormatException(
        message: message,
        source: bytes,
        offset: offset,
      );
    }
    warning(
      message,
      offset,
      curveIndex: curveIndex,
      channelIndex: channelIndex,
      section: section,
    );
  }

  /// Adds one warning without consulting the strictness policy.
  void warning(
    String message,
    int offset, {
    int? curveIndex,
    int? channelIndex,
    AcvCurveSection? section,
  }) {
    warnings.add(
      AcvWarning(
        message: message,
        offset: offset,
        curveIndex: curveIndex,
        channelIndex: channelIndex,
        section: section,
      ),
    );
  }

  /// Preserves all source bytes beginning at [offset] as uninterpreted data.
  void setTrailing(int offset) {
    trailingByteCount = bytes.length - offset;
    trailingData = options.preserveTrailingData ? Uint8List.fromList(Uint8List.sublistView(bytes, offset)) : Uint8List(0);
  }

  /// Freezes accumulated values into the public immutable representation.
  AcvFile build() {
    final String? marker = supplementalMarker;
    final int? sectionVersion = supplementalVersion;
    final int? sectionOffset = supplementalOffset;
    final int? declaredCurveCount = supplementalDeclaredCurveCount;
    final AcvSupplementalSection? section = marker == null || sectionVersion == null || sectionOffset == null || declaredCurveCount == null
        ? null
        : AcvSupplementalSection(
            marker: marker,
            version: sectionVersion,
            sourceOffset: sectionOffset,
            declaredCurveCount: declaredCurveCount,
            curves: supplementalCurves,
          );
    return AcvFile(
      version: version,
      headerValue: headerValue,
      primaryCurves: primaryCurves,
      supplementalSection: section,
      trailingData: trailingData,
      trailingByteCount: trailingByteCount,
      sourceData: options.preserveSourceData ? bytes : null,
      warnings: warnings,
    );
  }
}
