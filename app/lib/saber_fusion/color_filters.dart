import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

enum CanvasColorFilterMode {
  normal,
  smartDark,
  amoledDark,
  sepia;

  String get displayName => switch (this) {
    CanvasColorFilterMode.normal => '原色纸面',
    CanvasColorFilterMode.smartDark => '护眼深色反色',
    CanvasColorFilterMode.amoledDark => '纯黑反色',
    CanvasColorFilterMode.sepia => '暖黄护眼纸',
  };

  PhosphorIconData get icon => switch (this) {
    CanvasColorFilterMode.normal => PhosphorIconsLight.sun,
    CanvasColorFilterMode.smartDark => PhosphorIconsLight.moon,
    CanvasColorFilterMode.amoledDark => PhosphorIconsLight.circleHalf,
    CanvasColorFilterMode.sepia => PhosphorIconsLight.eye,
  };

  CanvasColorFilterMode get next =>
      CanvasColorFilterMode.values[(index + 1) % CanvasColorFilterMode.values.length];
}

// Saber-inspired Rec.709 hue-preserving luminance inversion & eye-care matrices.
const _smartDarkFilter = ColorFilter.matrix(<double>[
  0.459, -1.144, -0.115, 0, 230,
  -0.341, -0.344, -0.115, 0, 230,
  -0.341, -1.144, 0.685, 0, 230,
  0, 0, 0, 1, 0,
]);

const _amoledDarkFilter = ColorFilter.matrix(<double>[
  0.574, -1.430, -0.144, 0, 255,
  -0.426, -0.430, -0.144, 0, 255,
  -0.426, -1.430, 0.856, 0, 255,
  0, 0, 0, 1, 0,
]);

const _sepiaFilter = ColorFilter.matrix(<double>[
  0.98, 0.02, 0.00, 0, 0,
  0.00, 0.94, 0.01, 0, 0,
  0.00, 0.00, 0.84, 0, 0,
  0, 0, 0, 1, 0,
]);

ColorFilter? canvasColorFilterFor(CanvasColorFilterMode mode) => switch (mode) {
  CanvasColorFilterMode.normal => null,
  CanvasColorFilterMode.smartDark => _smartDarkFilter,
  CanvasColorFilterMode.amoledDark => _amoledDarkFilter,
  CanvasColorFilterMode.sepia => _sepiaFilter,
};
