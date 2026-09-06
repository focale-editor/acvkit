import 'dart:typed_data';

import 'package:acvkit/src/model/acv_curve.dart';
import 'package:acvkit/src/model/acv_options.dart';

/// Identifies one RGB table component in Photoshop Indexed Color mode.
enum AcvIndexedColorComponent {
  /// Red portion stored in the second curve slot.
  red(curvePosition: 1),

  /// Green portion stored in the third curve slot.
  green(curvePosition: 2),

  /// Blue portion stored in the fourth curve slot.
  blue(curvePosition: 3);

  /// Zero-based position occupied by this component in ACV curve order.
  final int curvePosition;

  /// Creates one component-to-position mapping from the published layout.
  const AcvIndexedColorComponent({
    required this.curvePosition,
  });
}

/// Channel-indexed curve section optionally appended to version 1 ACV files.
final class AcvSupplementalSection {
  /// Four-byte section marker, normally `Crv `.
  final String marker;

  /// Supplemental-section version, normally 4.
  final int version;

  /// Absolute offset of [marker], or `-1` for newly authored data.
  final int sourceOffset;

  /// Curve count declared by the 32-bit section header.
  final int declaredCurveCount;

  /// Successfully decoded channel-indexed curves in source order.
  final List<AcvCurve> curves;

  /// Creates an immutable supplemental section with complete source metadata.
  AcvSupplementalSection({
    required this.marker,
    required this.version,
    required this.sourceOffset,
    required this.declaredCurveCount,
    required List<AcvCurve> curves,
  }) : curves = List<AcvCurve>.unmodifiable(curves);

  /// Creates a canonical `Crv ` section for newly authored curves.
  factory AcvSupplementalSection.editable({
    required List<AcvCurve> curves,
  }) {
    final List<AcvCurve> normalizedCurves = _normalizeCurves(
      curves,
      AcvCurveSection.supplemental,
    );
    return AcvSupplementalSection(
      marker: 'Crv ',
      version: 4,
      sourceOffset: -1,
      declaredCurveCount: normalizedCurves.length,
      curves: normalizedCurves,
    );
  }

  /// Whether every curve declared by the section header was decoded.
  bool get isComplete => curves.length == declaredCurveCount;

  /// Whether the section follows every published structural constraint.
  bool get isOfficial {
    if (marker != 'Crv ' || version != 4 || declaredCurveCount < 1 || declaredCurveCount > 19 || !isComplete) {
      return false;
    }
    for (final AcvCurve curve in curves) {
      if (curve.channelIndex < 0 || curve.channelIndex > 0xffff || !curve.isOfficial) {
        return false;
      }
    }
    return true;
  }

  /// Returns the last curve matching [channelIndex], or `null` when absent.
  AcvCurve? curveForChannel(int channelIndex) {
    for (int index = curves.length - 1; index >= 0; index--) {
      if (curves[index].channelIndex == channelIndex) {
        return curves[index];
      }
    }
    return null;
  }
}

/// Complete decoded or newly authored Adobe Photoshop curves document.
final class AcvFile {
  /// ACV container version exactly as stored.
  final int version;

  /// Version-dependent second 16-bit header value.
  ///
  /// Version 4 interprets this value as a curve count. Version 1 interprets it
  /// as a bitmap whose set bits identify primary curve channels.
  final int headerValue;

  /// Curves stored directly after the four-byte file header.
  final List<AcvCurve> primaryCurves;

  /// Optional channel-indexed extension found in a version 1 file.
  final AcvSupplementalSection? supplementalSection;

  /// Bytes that could not be interpreted, or an empty list when not preserved.
  final Uint8List trailingData;

  /// Uninterpreted byte count, even when preservation was disabled.
  final int trailingByteCount;

  /// Complete encoded input, or `null` when source preservation was disabled.
  final Uint8List? sourceData;

  /// Recoverable compatibility issues encountered while decoding.
  final List<AcvWarning> warnings;

  /// Creates an immutable ACV document with explicit source metadata.
  AcvFile({
    required this.version,
    required this.headerValue,
    required List<AcvCurve> primaryCurves,
    required this.supplementalSection,
    required Uint8List trailingData,
    required this.trailingByteCount,
    required Uint8List? sourceData,
    required List<AcvWarning> warnings,
  }) : primaryCurves = List<AcvCurve>.unmodifiable(primaryCurves),
       trailingData = Uint8List.fromList(trailingData).asUnmodifiableView(),
       sourceData = sourceData == null ? null : Uint8List.fromList(sourceData).asUnmodifiableView(),
       warnings = List<AcvWarning>.unmodifiable(warnings);

  /// Creates a canonical version 4 document for newly authored [curves].
  factory AcvFile.versionFour({
    required List<AcvCurve> curves,
  }) {
    final List<AcvCurve> normalizedCurves = _normalizeCurves(
      curves,
      AcvCurveSection.primary,
    );
    return AcvFile(
      version: 4,
      headerValue: normalizedCurves.length,
      primaryCurves: normalizedCurves,
      supplementalSection: null,
      trailingData: Uint8List(0),
      trailingByteCount: 0,
      sourceData: null,
      warnings: const [],
    );
  }

  /// Creates a canonical version 1 document for newly authored curves.
  factory AcvFile.versionOne({
    required List<AcvCurve> primaryCurves,
    List<AcvCurve> supplementalCurves = const [],
  }) {
    final List<AcvCurve> sortedPrimaryCurves = List<AcvCurve>.of(primaryCurves)..sort((left, right) => left.channelIndex.compareTo(right.channelIndex));
    final List<AcvCurve> normalizedPrimaryCurves = _normalizeCurves(
      sortedPrimaryCurves,
      AcvCurveSection.primary,
    );
    final int bitmap = _versionOneBitmap(normalizedPrimaryCurves);
    final AcvSupplementalSection? section = supplementalCurves.isEmpty
        ? null
        : AcvSupplementalSection.editable(
            curves: supplementalCurves,
          );
    return AcvFile(
      version: 1,
      headerValue: bitmap,
      primaryCurves: normalizedPrimaryCurves,
      supplementalSection: section,
      trailingData: Uint8List(0),
      trailingByteCount: 0,
      sourceData: null,
      warnings: const [],
    );
  }

  /// Number of primary curves declared by [headerValue].
  int get declaredPrimaryCurveCount => switch (version) {
    1 => _countSetBits(headerValue),
    4 => headerValue,
    _ => 0,
  };

  /// Channel indices selected by a version 1 primary-curve bitmap.
  List<int> get primaryChannelIndices {
    if (version == 4) {
      return List<int>.unmodifiable(
        List<int>.generate(headerValue, (index) => index),
      );
    }
    if (version != 1) {
      return const [];
    }
    return List<int>.unmodifiable([
      for (int index = 0; index < 16; index++)
        if (headerValue & (1 << index) != 0) index,
    ]);
  }

  /// Curves preferred for rendering, favoring a non-empty supplemental section.
  List<AcvCurve> get effectiveCurves {
    final AcvSupplementalSection? section = supplementalSection;
    return section == null || section.curves.isEmpty ? primaryCurves : section.curves;
  }

  /// Whether the file uses one of the two published container versions.
  bool get hasSupportedVersion => version == 1 || version == 4;

  /// Whether every curve announced by parsed headers was decoded.
  bool get isComplete {
    final AcvSupplementalSection? section = supplementalSection;
    return hasSupportedVersion && primaryCurves.length == declaredPrimaryCurveCount && (section == null || section.isComplete);
  }

  /// Whether the complete document follows every published ACV constraint.
  bool get isOfficial {
    if (!isComplete || trailingByteCount != 0 || warnings.isNotEmpty) {
      return false;
    }
    if (version == 4) {
      if (headerValue < 1 || headerValue > 19 || supplementalSection != null) {
        return false;
      }
      for (int index = 0; index < primaryCurves.length; index++) {
        if (primaryCurves[index].channelIndex != index || !primaryCurves[index].isOfficial) {
          return false;
        }
      }
      return true;
    }
    final AcvSupplementalSection? section = supplementalSection;
    if (headerValue == 0 || headerValue > 0xffff || (section != null && !section.isOfficial)) {
      return false;
    }
    final List<int> channels = primaryChannelIndices;
    for (int index = 0; index < primaryCurves.length; index++) {
      if (primaryCurves[index].channelIndex != channels[index] || !primaryCurves[index].isOfficial) {
        return false;
      }
    }
    return true;
  }

  /// Returns the preferred curve at zero-based encoded [position].
  ///
  /// Positions describe source curve order, not necessarily an image channel.
  /// Photoshop Indexed Color mode gives positions one through three special
  /// red, green, and blue color-table meanings.
  AcvCurve? curveAtPosition(int position) {
    if (position < 0 || position >= effectiveCurves.length) {
      return null;
    }
    return effectiveCurves[position];
  }

  /// Returns the preferred curve for [channelIndex], or `null` when absent.
  ///
  /// A matching supplemental curve wins over a primary curve because the
  /// version 1 extension stores explicit channel assignments.
  AcvCurve? curveForChannel(int channelIndex) {
    final AcvCurve? supplementalCurve = supplementalSection?.curveForChannel(channelIndex);
    if (supplementalCurve != null) {
      return supplementalCurve;
    }
    for (int index = primaryCurves.length - 1; index >= 0; index--) {
      if (primaryCurves[index].channelIndex == channelIndex) {
        return primaryCurves[index];
      }
    }
    return null;
  }

  /// Returns the RGB table curve for [component] in Indexed Color mode.
  AcvCurve? indexedColorTableCurve(AcvIndexedColorComponent component) => curveAtPosition(component.curvePosition);

  /// Returns an active alpha-channel curve in Indexed Color mode.
  ///
  /// Indexed Color reserves positions one through three for its color table,
  /// so Photoshop channel indices 2 through 16 occupy positions 4 through 18.
  AcvCurve? indexedColorAlphaCurve(int channelIndex) {
    if (channelIndex < 2 || channelIndex > 16) {
      throw RangeError.range(channelIndex, 2, 16, 'channelIndex');
    }
    return curveAtPosition(channelIndex + 2);
  }

  /// Composite curve at channel zero, when present.
  AcvCurve? get compositeCurve => curveForChannel(0);

  /// RGB red curve at channel one, when present.
  AcvCurve? get redCurve => curveForChannel(1);

  /// RGB green curve at channel two, when present.
  AcvCurve? get greenCurve => curveForChannel(2);

  /// RGB blue curve at channel three, when present.
  AcvCurve? get blueCurve => curveForChannel(3);
}

/// Recreates curve objects with canonical metadata for a new section.
List<AcvCurve> _normalizeCurves(
  List<AcvCurve> curves,
  AcvCurveSection section,
) => List<AcvCurve>.unmodifiable([
  for (final (int index, AcvCurve curve) in curves.indexed)
    AcvCurve(
      index: index,
      channelIndex: curve.channelIndex,
      section: section,
      sourceOffset: -1,
      declaredPointCount: curve.points.length,
      points: curve.points,
      recordData: null,
    ),
]);

/// Builds a version 1 channel bitmap while rejecting ambiguous inputs.
int _versionOneBitmap(List<AcvCurve> curves) {
  int bitmap = 0;
  for (final AcvCurve curve in curves) {
    final int channelIndex = curve.channelIndex;
    if (channelIndex < 0 || channelIndex > 15) {
      throw ArgumentError.value(channelIndex, 'primaryCurves', 'Version 1 primary channels must be between 0 and 15');
    }
    final int channelBit = 1 << channelIndex;
    if (bitmap & channelBit != 0) {
      throw ArgumentError.value(channelIndex, 'primaryCurves', 'Version 1 primary channel indices must be unique');
    }
    bitmap |= channelBit;
  }
  return bitmap;
}

/// Counts set bits in one non-negative 16-bit bitmap.
int _countSetBits(int value) {
  int remaining = value & 0xffff;
  int count = 0;
  while (remaining != 0) {
    remaining &= remaining - 1;
    count++;
  }
  return count;
}
