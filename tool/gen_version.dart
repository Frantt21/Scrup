import 'dart:io';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final match = RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(pubspec);
  if (match == null) {
    stderr.writeln('Could not find version in pubspec.yaml');
    exit(1);
  }
  final version = match.group(1)!.trim();
  // Split "1.0.0+2" into "1.0.0" (display) and "2" (build)
  final parts = version.split('+');
  final display = parts[0];
  final build = parts.length > 1 ? parts[1] : '0';

  final out = File('lib/core/version.g.dart');
  out.writeAsStringSync('''// GENERATED CODE - DO NOT MODIFY BY HAND
// Run: dart run tool/gen_version.dart

const String kAppVersion = '$display';
const String kAppBuildNumber = '$build';
const String kAppVersionFull = '$version';
''');
  stdout.writeln('Generated ${out.path} with version $version');
}
