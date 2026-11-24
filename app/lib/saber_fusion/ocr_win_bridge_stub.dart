import 'dart:typed_data';

import 'package:butterfly/saber_fusion/ocr_models.dart';

bool get isWinNativeOcrSupported => false;

Future<List<OcrTextLine>?> recognizeWinRgba({
  required Uint8List rgbaBytes,
  required int width,
  required int height,
  required String langTag,
}) async => null;
