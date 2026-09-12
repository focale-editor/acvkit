import 'dart:convert';
import 'dart:typed_data';

import 'package:acvkit/src/codec/acv_decoder.dart';
import 'package:acvkit/src/codec/acv_encoder.dart';
import 'package:acvkit/src/model/acv_file.dart';
import 'package:acvkit/src/model/acv_options.dart';

/// Converts ACV models to and from their binary representation.
///
/// Each conversion handles one complete in-memory file. The encoded type is
/// [List<int>] so this codec can be composed with standard `dart:convert`
/// codecs, while [encode] keeps the more precise [Uint8List] return type.
final class AcvCodec extends Codec<AcvFile, List<int>> {
  /// Options applied while decoding.
  final AcvDecodeOptions decodeOptions;

  /// Options applied while encoding.
  final AcvEncodeOptions encodeOptions;

  /// Creates a reusable codec with fixed decoding and encoding options.
  const AcvCodec({
    this.decodeOptions = const AcvDecodeOptions(),
    this.encodeOptions = const AcvEncodeOptions(),
  });

  @override
  AcvDecoder get decoder => AcvDecoder(options: decodeOptions);

  @override
  AcvEncoder get encoder => AcvEncoder(options: encodeOptions);

  @override
  Uint8List encode(AcvFile input) => encoder.convert(input);
}
