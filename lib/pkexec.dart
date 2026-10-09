import 'dart:convert';
import 'dart:io';

class RunResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  RunResult(this.exitCode, this.stdout, this.stderr);

  bool get ok => exitCode == 0;
}

class PkexecCancelled implements Exception {
  final String message;

  PkexecCancelled(this.message);

  @override
  String toString() => message;
}

bool _isCancellation(String err) =>
    err.contains('Not authorized') ||
    err.contains('dismissed') ||
    err.toLowerCase().contains('cancel');

Future<RunResult> runRoot(List<String> args, {String? input}) async {
  final p = await Process.start('pkexec', args);
  if (input != null) p.stdin.write(input);
  await p.stdin.close();
  final out = await p.stdout.transform(utf8.decoder).join();
  final err = await p.stderr.transform(utf8.decoder).join();
  final code = await p.exitCode;
  if (code != 0 && _isCancellation('$err\n$out')) {
    throw PkexecCancelled('Autenticación cancelada');
  }
  return RunResult(code, out, err);
}

Future<String> readRoot(String path) async {
  final r = await runRoot(['cat', path]);
  if (!r.ok) throw Exception('No se pudo leer $path: ${r.stderr}');
  return r.stdout;
}

/// Escribe [content] en [path] como root, creando antes un backup.
/// Devuelve la ruta del backup creado (para poder restaurar con [restoreBackups]).
Future<String> writeRoot(String path, String content) async {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final backup = '$path.bak-$stamp';
  final cp = await runRoot(['cp', '-a', path, backup]);
  if (!cp.ok) throw Exception('No se pudo crear el backup: ${cp.stderr}');
  final text = content.endsWith('\n') ? content : '$content\n';
  final r = await runRoot(['tee', path], input: text);
  if (!r.ok) throw Exception('No se pudo escribir $path: ${r.stderr}');
  return backup;
}

Future<RunResult> regenerateGrub() =>
    runRoot(['grub-mkconfig', '-o', '/boot/grub/grub.cfg']);

Future<RunResult> restoreBackups(Map<String, String> backups) {
  final parts = backups.entries
      .map((e) => 'cp -a "${e.value}" "${e.key}"')
      .join(' && ');
  return runRoot(['sh', '-c', parts]);
}
