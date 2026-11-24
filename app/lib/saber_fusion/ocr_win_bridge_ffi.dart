import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:butterfly/saber_fusion/ocr_models.dart';

typedef _NativeAlloc = Pointer<Uint8> Function(Int32 size);
typedef _DartAlloc = Pointer<Uint8> Function(int size);

typedef _NativeFree = Void Function(Pointer<Void> ptr);
typedef _DartFree = void Function(Pointer<Void> ptr);

typedef _NativeRecognize =
    Pointer<Uint8> Function(
      Pointer<Uint8> pixels,
      Int32 width,
      Int32 height,
      Int32 isRgba,
      Pointer<Uint8> langTag,
    );
typedef _DartRecognize =
    Pointer<Uint8> Function(
      Pointer<Uint8> pixels,
      int width,
      int height,
      int isRgba,
      Pointer<Uint8> langTag,
    );

bool get isWinNativeOcrSupported => Platform.isWindows;

DynamicLibrary? _tryOpenOcrLibrary() {
  if (!Platform.isWindows) return null;
  final candidates = <String>[
    'win_ocr_bridge.dll',
    '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}win_ocr_bridge.dll',
  ];
  for (final path in candidates) {
    try {
      return DynamicLibrary.open(path);
    } catch (_) {
      // Try next lookup path.
    }
  }
  return null;
}

Map<String, dynamic> _recognizeInIsolate(
  Uint8List rgbaBytes,
  int width,
  int height,
  String langTag,
) {
  final lib = _tryOpenOcrLibrary();
  if (lib == null) {
    return const {'ok': false, 'error': 'win_ocr_bridge.dll not found'};
  }

  final alloc = lib.lookupFunction<_NativeAlloc, _DartAlloc>('bfly_ocr_alloc');
  final free = lib.lookupFunction<_NativeFree, _DartFree>('bfly_ocr_free');
  final recognize = lib.lookupFunction<_NativeRecognize, _DartRecognize>(
    'bfly_ocr_recognize_bgra',
  );

  final pixelPtr = alloc(rgbaBytes.length);
  if (pixelPtr == nullptr) {
    return const {'ok': false, 'error': 'native allocation failed'};
  }

  final langBytes = utf8.encode(langTag);
  final langPtr = alloc(langBytes.length + 1);
  if (langPtr == nullptr) {
    free(pixelPtr.cast());
    return const {'ok': false, 'error': 'native lang allocation failed'};
  }

  Pointer<Uint8> outPtr = nullptr;
  try {
    pixelPtr.asTypedList(rgbaBytes.length).setAll(0, rgbaBytes);
    final langView = langPtr.asTypedList(langBytes.length + 1);
    langView.setAll(0, langBytes);
    langView[langBytes.length] = 0;

    outPtr = recognize(pixelPtr, width, height, 1, langPtr);
  } finally {
    free(pixelPtr.cast());
    free(langPtr.cast());
  }

  if (outPtr == nullptr) {
    return const {'ok': false, 'error': 'empty native ocr response'};
  }

  try {
    var len = 0;
    while (outPtr[len] != 0) {
      len++;
    }
    final jsonStr = utf8.decode(outPtr.asTypedList(len), allowMalformed: true);
    final decoded = jsonDecode(jsonStr);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
    return const {'ok': false, 'error': 'malformed ocr json'};
  } catch (e) {
    return {'ok': false, 'error': e.toString()};
  } finally {
    free(outPtr.cast());
  }
}

Future<List<OcrTextLine>?> recognizeWinRgba({
  required Uint8List rgbaBytes,
  required int width,
  required int height,
  required String langTag,
}) async {
  if (!Platform.isWindows || width <= 0 || height <= 0) return null;
  final payload = await Isolate.run(
    () => _recognizeInIsolate(rgbaBytes, width, height, langTag),
  );
  if (payload['ok'] != true) {
    final err = payload['error']?.toString();
    if (err != null && err.isNotEmpty) {
      throw StateError(err);
    }
    return null;
  }

  final rawLines = payload['lines'];
  if (rawLines is! List) return const [];
  final parsed = <OcrTextLine>[];
  for (final item in rawLines) {
    if (item is Map) {
      parsed.add(
        OcrTextLine.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
      );
    }
  }
  return parsed;
}
