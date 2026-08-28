import 'dart:io';
import 'dart:convert';

final categories = {
  "en": {"shortcutCategoryPlayback": "Playback", "shortcutCategoryVolume": "Volume", "shortcutCategoryNavigation": "Navigation", "shortcutCategoryModes": "Modes"},
  "es": {"shortcutCategoryPlayback": "Reproducción", "shortcutCategoryVolume": "Volumen", "shortcutCategoryNavigation": "Navegación", "shortcutCategoryModes": "Modos"},
  "pt": {"shortcutCategoryPlayback": "Reprodução", "shortcutCategoryVolume": "Volume", "shortcutCategoryNavigation": "Navegação", "shortcutCategoryModes": "Modos"},
  "pt_BR": {"shortcutCategoryPlayback": "Reprodução", "shortcutCategoryVolume": "Volume", "shortcutCategoryNavigation": "Navegação", "shortcutCategoryModes": "Modos"},
  "ru": {"shortcutCategoryPlayback": "Воспроизведение", "shortcutCategoryVolume": "Громкость", "shortcutCategoryNavigation": "Навигация", "shortcutCategoryModes": "Режимы"},
  "ja": {"shortcutCategoryPlayback": "再生", "shortcutCategoryVolume": "音量", "shortcutCategoryNavigation": "ナビゲーション", "shortcutCategoryModes": "モード"},
  "ko": {"shortcutCategoryPlayback": "재생", "shortcutCategoryVolume": "볼륨", "shortcutCategoryNavigation": "탐색", "shortcutCategoryModes": "모드"},
  "zh": {"shortcutCategoryPlayback": "播放", "shortcutCategoryVolume": "音量", "shortcutCategoryNavigation": "导航", "shortcutCategoryModes": "模式"},
};

void main() {
  for (final entry in categories.entries) {
    final f = File('lib/l10n/app_${entry.key}.arb');
    final data = json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    data.addAll(entry.value);
    f.writeAsStringSync(JsonEncoder.withIndent('  ').convert(data));
    print('OK: ${entry.key}');
  }
}
