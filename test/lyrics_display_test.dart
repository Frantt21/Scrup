import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrup/core/synced_lyrics.dart';
import 'package:scrup/l10n/generated/app_localizations.dart';
import 'package:scrup/ui/widgets/lyrics_display.dart';

/// Regresión: la línea ACTIVA (sweep) debe renderizar exactamente los mismos
/// tokens que la estática. Los proveedores word-by-word traen espacios dobles
/// o iniciales dentro del texto de cada palabra; antes se pintaban crudos y
/// las palabras "se separaban" solo al ganar el foco.
void main() {
  final dirty = SyncedLyrics(
    songTitle: 'Tema',
    artist: 'Artista',
    lines: [
      LyricLine(
        timestamp: Duration.zero,
        text: 'Hola mundo',
        words: [
          // Doble espacio al final + espacio inicial en la siguiente:
          // datos tal cual llegan de KPoe/LRCLIB/TTML.
          KaraokeWord(timestamp: Duration.zero, text: 'Hola  '),
          KaraokeWord(
              timestamp: const Duration(milliseconds: 500), text: ' mundo'),
        ],
      ),
    ],
  );

  Widget buildDisplay({
    required int? currentIndex,
    required bool sweep,
    required ValueNotifier<Duration> position,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LyricsDisplay(
          lyrics: dirty,
          currentIndexNotifier: ValueNotifier<int?>(currentIndex),
          positionNotifier: position,
          sweepEnabled: sweep,
        ),
      ),
    );
  }

  /// Une el texto visible de la línea karaoke (Texts con fontSize 30).
  String joinedLineText(WidgetTester tester) {
    final texts = tester.widgetList<Text>(
      find.byWidgetPredicate((w) => w is Text && w.style?.fontSize == 30),
    );
    return texts.map((t) => t.data ?? '').join();
  }

  testWidgets('línea estática renderiza tokens limpios', (tester) async {
    await tester.pumpWidget(buildDisplay(
      currentIndex: null,
      sweep: true,
      position: ValueNotifier<Duration>(Duration.zero),
    ));
    await tester.pumpAndSettle();
    expect(joinedLineText(tester), 'Hola mundo');
  });

  testWidgets('línea activa con sweep usa los mismos tokens que la estática',
      (tester) async {
    await tester.pumpWidget(buildDisplay(
      currentIndex: 0,
      sweep: true,
      position: ValueNotifier<Duration>(const Duration(milliseconds: 250)),
    ));
    await tester.pumpAndSettle();
    expect(joinedLineText(tester), 'Hola mundo');
  });

  testWidgets('sin palabras karaoke cae al texto plano sin huecos',
      (tester) async {
    final plain = SyncedLyrics(
      songTitle: 'Tema',
      artist: 'Artista',
      lines: [LyricLine(timestamp: Duration.zero, text: 'Solo texto')],
    );
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LyricsDisplay(
          lyrics: plain,
          currentIndexNotifier: ValueNotifier<int?>(0),
          positionNotifier: ValueNotifier<Duration>(Duration.zero),
          sweepEnabled: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(joinedLineText(tester), 'Solo texto');
  });
}
