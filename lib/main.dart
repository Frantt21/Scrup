import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'core/binaries.dart';
import 'data/database.dart';
import 'services/player_service.dart';
import 'services/ytdlp_service.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  Binaries.logBinaries();

  runApp(const ScrupApp());
}

class ScrupApp extends StatelessWidget {
  const ScrupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>(create: (_) => AppDatabase()),
        Provider<YtDlpService>(create: (_) => YtDlpService()),
        Provider<PlayerService>(
          create: (_) => PlayerService(),
          dispose: (_, player) => player.dispose(),
        ),
      ],
      child: MaterialApp(
        title: 'Scrup',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFE91E63),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}
