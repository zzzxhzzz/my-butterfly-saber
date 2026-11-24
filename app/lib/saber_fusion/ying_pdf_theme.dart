import 'package:material_ui/material_ui.dart';

class YingPdfPalette {
  final Color canvasBackdrop;
  final Color headerSurface;
  final Color inspectorSurface;
  final Color cardSurface;
  final Color controlSurface;
  final Color pillSurface;
  final Color borderSubtle;
  final Color borderStrong;
  final Color accentBerry;
  final Color accentBerryDark;
  final Color accentSoft;
  final Color selectionHighlight;
  final Color inkPrimary;
  final Color inkSecondary;
  final Color inkMuted;
  final Color trackFill;
  final Color progressBar;

  const YingPdfPalette({
    required this.canvasBackdrop,
    required this.headerSurface,
    required this.inspectorSurface,
    required this.cardSurface,
    required this.controlSurface,
    required this.pillSurface,
    required this.borderSubtle,
    required this.borderStrong,
    required this.accentBerry,
    required this.accentBerryDark,
    required this.accentSoft,
    required this.selectionHighlight,
    required this.inkPrimary,
    required this.inkSecondary,
    required this.inkMuted,
    required this.trackFill,
    required this.progressBar,
  });

  static const light = YingPdfPalette(
    canvasBackdrop: Color(0xFFECE6E9),
    headerSurface: Color(0xFFFAF6F7),
    inspectorSurface: Color(0xFFF8F3F5),
    cardSurface: Color(0xFFF3ECF0),
    controlSurface: Color(0xFFFFFFFF),
    pillSurface: Color(0xFFEFE7EB),
    borderSubtle: Color(0xFFE4DADF),
    borderStrong: Color(0xFFD5C6CD),
    accentBerry: Color(0xFFB83253),
    accentBerryDark: Color(0xFF992341),
    accentSoft: Color(0xFFF4DCE3),
    selectionHighlight: Color(0x5CE08BA2),
    inkPrimary: Color(0xFF282024),
    inkSecondary: Color(0xFF5D5057),
    inkMuted: Color(0xFF8C7E85),
    trackFill: Color(0xFFE2D7DD),
    progressBar: Color(0xFF4A3E44),
  );

  static const dark = YingPdfPalette(
    canvasBackdrop: Color(0xFF1A1618),
    headerSurface: Color(0xFF241E21),
    inspectorSurface: Color(0xFF211B1E),
    cardSurface: Color(0xFF2B2327),
    controlSurface: Color(0xFF33292E),
    pillSurface: Color(0xFF362C31),
    borderSubtle: Color(0xFF40343A),
    borderStrong: Color(0xFF52434B),
    accentBerry: Color(0xFFE06281),
    accentBerryDark: Color(0xFFC44666),
    accentSoft: Color(0xFF4B2834),
    selectionHighlight: Color(0x66E06281),
    inkPrimary: Color(0xFFF5EEF1),
    inkSecondary: Color(0xFFD0C3C9),
    inkMuted: Color(0xFF9A8B92),
    trackFill: Color(0xFF493C43),
    progressBar: Color(0xFFE06281),
  );

  static YingPdfPalette of(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? dark : light;
  }
}

ThemeData applyYingPdfTheme(ThemeData base, {required bool dark}) {
  final palette = dark ? YingPdfPalette.dark : YingPdfPalette.light;
  final scheme = base.colorScheme.copyWith(
    primary: palette.accentBerry,
    onPrimary: Colors.white,
    primaryContainer: palette.accentSoft,
    onPrimaryContainer: palette.accentBerryDark,
    secondary: palette.accentBerry,
    secondaryContainer: palette.pillSurface,
    surface: palette.headerSurface,
    onSurface: palette.inkPrimary,
    onSurfaceVariant: palette.inkSecondary,
    surfaceContainerLowest: palette.controlSurface,
    surfaceContainerLow: palette.inspectorSurface,
    surfaceContainer: palette.cardSurface,
    surfaceContainerHigh: palette.pillSurface,
    surfaceContainerHighest: palette.trackFill,
    surfaceDim: palette.canvasBackdrop,
    outline: palette.borderStrong,
    outlineVariant: palette.borderSubtle,
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.canvasBackdrop,
    cardColor: palette.cardSurface,
    dividerColor: palette.borderSubtle,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: palette.headerSurface,
      foregroundColor: palette.inkPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: palette.inkMuted,
      inactiveTrackColor: palette.trackFill,
      thumbColor: Colors.white,
      overlayColor: palette.accentBerry.withValues(alpha: 0.14),
      trackHeight: 4,
    ),
  );
}
