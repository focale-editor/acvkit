import 'package:acvkit/src/model/acv_curve.dart';
import 'package:pscore/pscore.dart';

/// Controls whether recoverable ACV compatibility issues stop decoding.
enum AcvDecodeMode {
  /// Rejects every nonstandard value, extension, and trailing byte.
  strict,

  /// Preserves nonstandard data and reports recoverable defects as warnings.
  tolerant,
}

/// Controls how strongly an ACV document is validated before encoding.
enum AcvEncodeMode {
  /// Produces only documents conforming to the published ACV format.
  strict,

  /// Writes all representable model values, including preserved damage.
  permissive,
}

/// Resource and preservation limits applied while decoding an ACV file.
final class AcvDecodeOptions {
  /// Handling policy for recoverable format extensions and damaged records.
  final AcvDecodeMode mode;

  /// Maximum accepted input size.
  final int maxFileBytes;

  /// Maximum curve count accepted in either ACV section.
  final int maxCurvesPerSection;

  /// Maximum point count accepted in one curve.
  final int maxPointsPerCurve;

  /// Maximum aggregate point count accepted across the complete file.
  final int maxTotalPoints;

  /// Whether each curve retains its exact section-specific record bytes.
  final bool preserveCurveData;

  /// Whether the decoded document retains a complete source copy.
  final bool preserveSourceData;

  /// Whether bytes that cannot be interpreted are retained.
  final bool preserveTrailingData;

  /// Creates bounded decode options suitable for untrusted input.
  const AcvDecodeOptions({
    this.mode = AcvDecodeMode.tolerant,
    this.maxFileBytes = 16 * 1024 * 1024,
    this.maxCurvesPerSection = 4096,
    this.maxPointsPerCurve = 4096,
    this.maxTotalPoints = 1000000,
    this.preserveCurveData = true,
    this.preserveSourceData = true,
    this.preserveTrailingData = true,
  });
}

/// Preservation and validation choices applied while encoding an ACV file.
final class AcvEncodeOptions {
  /// Validation policy applied before values are written.
  final AcvEncodeMode mode;

  /// Whether a modeled version 1 supplemental section is written.
  final bool includeSupplementalSection;

  /// Whether uninterpreted trailing bytes are appended.
  final bool includeTrailingData;

  /// Creates encoding options for a standards-compliant output by default.
  const AcvEncodeOptions({
    this.mode = AcvEncodeMode.strict,
    this.includeSupplementalSection = true,
    this.includeTrailingData = true,
  });
}

/// Describes a recoverable compatibility issue found while decoding.
final class AcvWarning extends PsWarning {
  /// Zero-based curve position within its section, when known.
  final int? curveIndex;

  /// Photoshop channel index associated with the issue, when known.
  final int? channelIndex;

  /// Section containing the issue, when known.
  final AcvCurveSection? section;

  /// Creates a warning with optional source context.
  const AcvWarning({
    required super.message,
    super.offset,
    this.curveIndex,
    this.channelIndex,
    this.section,
  });

  @override
  String get typeName => 'AcvWarning';

  @override
  String get context {
    final int? currentCurveIndex = curveIndex;
    final AcvCurveSection? currentSection = section;
    final String curve = currentCurveIndex == null ? '' : ' in curve ${currentCurveIndex + 1}';
    final String channel = channelIndex == null ? '' : ' for channel $channelIndex';
    final String sourceSection = currentSection == null ? '' : ' of ${currentSection.name}';
    return '$curve$channel$sourceSection';
  }
}

/// Reports malformed, truncated, unsupported, or unsafe ACV input.
final class AcvFormatException extends PsFormatException {
  /// Creates an error at an optional absolute byte [offset].
  const AcvFormatException({
    required super.message,
    super.source,
    super.offset,
  });

  @override
  String get typeName => 'AcvFormatException';
}

/// Reports model data that cannot be represented by the requested ACV output.
final class AcvWriteException extends PsWriteException {
  /// Creates an encoding error with a user-facing [message].
  const AcvWriteException({
    required super.message,
  });

  @override
  String get typeName => 'AcvWriteException';
}
