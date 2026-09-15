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
            timestamp: const Duration(milliseconds: 500),
            text: ' mundo',
          ),
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
          positionNotifier: position,
          sweepEnabled: sweep,
        ),
      ),
    );
  }

  /// Une el texto visible de la línea karaoke (Texts con fontSize 38).
  String joinedLineText(WidgetTester tester) {
    final texts = tester.widgetList<Text>(
      find.byWidgetPredicate((w) => w is Text && w.style?.fontSize == 38),
    );
    return texts.map((t) => t.data ?? '').join();
  }

  testWidgets('línea estática renderiza tokens limpios', (tester) async {
    await tester.pumpWidget(
      buildDisplay(
        currentIndex: null,
        sweep: true,
        position: ValueNotifier<Duration>(Duration.zero),
      ),
    );
    await tester.pumpAndSettle();
    expect(joinedLineText(tester), 'Hola mundo');
  });

  testWidgets('línea activa con sweep usa los mismos tokens que la estática', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildDisplay(
        currentIndex: 0,
        sweep: true,
        position: ValueNotifier<Duration>(const Duration(milliseconds: 250)),
      ),
    );
    await tester.pumpAndSettle();
    expect(joinedLineText(tester), 'Hola mundo');
  });

  testWidgets('sin palabras karaoke cae al texto plano sin huecos', (
    tester,
  ) async {
    final plain = SyncedLyrics(
      songTitle: 'Tema',
      artist: 'Artista',
      lines: [LyricLine(timestamp: Duration.zero, text: 'Solo texto')],
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LyricsDisplay(
            lyrics: plain,
            positionNotifier: ValueNotifier<Duration>(Duration.zero),
            sweepEnabled: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(joinedLineText(tester), 'Solo texto');
  });

  group('gaps de silencio (•••)', () {
    // Primera línea a los 12 s ⇒ se inserta un gap en t=0 (intro).
    final withIntro = SyncedLyrics(
      songTitle: 'Tema',
      artist: 'Artista',
      lines: [
        LyricLine(timestamp: const Duration(seconds: 12), text: 'Empieza'),
      ],
    );

    Widget introDisplay({
      required bool sweep,
      required ValueNotifier<Duration> position,
    }) {
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LyricsDisplay(
            lyrics: withIntro,
            positionNotifier: position,
            sweepEnabled: sweep,
          ),
        ),
      );
    }

    List<Color> dotColors(WidgetTester tester) {
      return tester
          .widgetList<Text>(
            find.byWidgetPredicate(
              (w) => w is Text && w.data == '•' && w.style?.fontSize == 38,
            ),
          )
          .map((t) => t.style!.color!)
          .toList();
    }

    testWidgets('gap activo con karaoke: barrido parcial sobre los puntos', (
      tester,
    ) async {
      // Mitad del hueco [0..12 s]: primer punto lleno, último sin empezar.
      await tester.pumpWidget(
        introDisplay(
          sweep: true,
          position: ValueNotifier<Duration>(const Duration(seconds: 6)),
        ),
      );
      await tester.pumpAndSettle();

      final colors = dotColors(tester);
      expect(colors, hasLength(3));
      expect(colors.first, Colors.white); // barrido completo
      expect(colors.last, Colors.white.withValues(alpha: 0.3)); // pendiente
    });

    testWidgets('gap activo sin karaoke: puntos encendidos en fijo', (
      tester,
    ) async {
      await tester.pumpWidget(
        introDisplay(
          sweep: false,
          position: ValueNotifier<Duration>(const Duration(seconds: 6)),
        ),
      );
      await tester.pumpAndSettle();

      expect(dotColors(tester), everyElement(Colors.white));
    });

    testWidgets('fuera del gap: puntos apagados y línea activa encendida', (
      tester,
    ) async {
      await tester.pumpWidget(
        introDisplay(
          sweep: true,
          position: ValueNotifier<Duration>(const Duration(seconds: 20)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        dotColors(tester),
        everyElement(Colors.white.withValues(alpha: 0.3)),
      );
    });
  });

  group('scroll', () {
    final manyLines = SyncedLyrics(
      songTitle: 'Tema',
      artist: 'Artista',
      lines: [
        for (var i = 0; i < 60; i++)
          LyricLine(
            timestamp: Duration(seconds: i * 2),
            text: 'Línea número $i de la canción',
          ),
      ],
    );

    testWidgets('el usuario puede scrollear a mano la lista', (tester) async {
      final position = ValueNotifier<Duration>(Duration.zero);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: LyricsDisplay(
                lyrics: manyLines,
                positionNotifier: position,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // El auto-scroll inicial centra la línea 0; la lista debe poder
      // moverse a mano desde ahí.
      final controller = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final start = controller.position.pixels;

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(
        controller.position.pixels,
        greaterThan(start + 100),
        reason: 'el drag manual debe mover la lista',
      );
    });

    testWidgets('el scroll funciona bajo el pan detector del miniplayer', (
      tester,
    ) async {
      // Imita la estructura del Miniplayer: GestureDetector con onPan*
      // envolviendo TODO el contenido (el panel del player).
      final position = ValueNotifier<Duration>(Duration.zero);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GestureDetector(
              onTap: () {},
              onPanStart: (_) {},
              onPanUpdate: (_) {},
              onPanEnd: (_) {},
              child: SizedBox(
                width: 400,
                height: 600,
                child: LyricsDisplay(
                  lyrics: manyLines,
                  positionNotifier: position,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controller = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final start = controller.position.pixels;

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(
        controller.position.pixels,
        greaterThan(start + 100),
        reason: 'el drag manual debe ganar al pan del panel',
      );
    });

    testWidgets('el scroll funciona con ShaderMask + Stack encima', (
      tester,
    ) async {
      // Imita la estructura real: ShaderMask envolviendo la lista y un
      // Stack hermano (botón de sync) encima.
      final position = ValueNotifier<Duration>(Duration.zero);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(
              children: [
                ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
                    stops: [0.0, 0.1, 0.9, 1.0],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: SizedBox(
                    width: 400,
                    height: 600,
                    child: LyricsDisplay(
                      lyrics: manyLines,
                      positionNotifier: position,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controller = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final start = controller.position.pixels;

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(
        controller.position.pixels,
        greaterThan(start + 100),
        reason: 'el ShaderMask no debe bloquear el scroll',
      );
    });
  });
}
