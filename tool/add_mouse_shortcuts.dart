import 'dart:io';
import 'dart:convert';

final translations = {
  "en": {"shortcutMouseBack": "Previous track (mouse)", "shortcutMouseForward": "Next track (mouse)"},
  "es": {"shortcutMouseBack": "Canción anterior (ratón)", "shortcutMouseForward": "Siguiente canción (ratón)"},
  "pt": {"shortcutMouseBack": "Música anterior (rato)", "shortcutMouseForward": "Próxima música (rato)"},
  "pt_BR": {"shortcutMouseBack": "Música anterior (mouse)", "shortcutMouseForward": "Próxima música (mouse)"},
  "ru": {"shortcutMouseBack": "Предыдущий трек (мышь)", "shortcutMouseForward": "Следующий трек (мышь)"},
  "ja": {"shortcutMouseBack": "前の曲 (マウス)", "shortcutMouseForward": "次の曲 (マウス)"},
  "ko": {"shortcutMouseBack": "이전 곡 (마우스)", "shortcutMouseForward": "다음 곡 (마우스)"},
  "zh": {"shortcutMouseBack": "上一首 (鼠标)", "shortcutMouseForward": "下一首 (鼠标)"},
};

void main() {
  for (final entry in translations.entries) {
    final f = File('lib/l10n/app_${entry.key}.arb');
    final data = json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    data.addAll(entry.value);
    f.writeAsStringSync(JsonEncoder.withIndent('  ').convert(data));
    print('OK: ${entry.key}');
  }
}
