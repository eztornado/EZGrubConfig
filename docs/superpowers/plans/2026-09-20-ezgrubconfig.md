# EZGrubConfig Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App Flutter de escritorio (Linux) para elegir la entrada GRUB por defecto, el timeout del menú y crear/editar/borrar entradas custom en `40_custom`, aplicándolo todo con `pkexec grub-mkconfig`.

**Architecture:** Toda la lógica GRUB (parseo de `grub.cfg`, lectura/escritura de `/etc/default/grub`, CRUD de `40_custom`) vive en Dart puro y testeable. La capa de privilegios es un envoltorio fino de `Process.run` sobre `pkexec`. Una sola pantalla Material con tres tarjetas + botón Aplicar.

**Tech Stack:** Flutter (desktop Linux), Dart 3, cero dependencias externas. Tests con `flutter_test`.

## Global Constraints

- Solo Linux. Rutas fijas: `/boot/grub/grub.cfg`, `/etc/default/grub`, `/etc/grub.d/40_custom`.
- Root exclusivamente vía `pkexec` (polkit); la app corre como usuario normal.
- Nombre del paquete/proyecto: `ezgrubconfig`. UI íntegramente en español.
- Cero paquetes externos en `pubspec.yaml` (solo Flutter SDK).
- Escritura siempre precedida de backup `<ruta>.bak-YYYYMMDD-HHMMSS`.
- Al modificar `/etc/default/grub` solo se tocan `GRUB_DEFAULT`, `GRUB_TIMEOUT` y `GRUB_TIMEOUT_STYLE`; el resto se conserva byte a byte.
- Spec: `docs/superpowers/specs/2026-09-20-ezgrubconfig-design.md`.

---

### Task 1: Scaffold del proyecto

**Files:**
- Create: `pubspec.yaml`, `lib/main.dart`, `linux/`, `test/widget_test.dart` (vía `flutter create`)
- Create: `.gitignore` (vía `flutter create`)

**Interfaces:**
- Consumes: nada.
- Produces: proyecto Flutter llamado `ezgrubconfig` que compila para Linux; `flutter test` en verde.

- [ ] **Step 1: Crear el scaffold en el directorio existente** (ya contiene `docs/` y `.git`; `flutter create` convive con ellos)

```bash
cd ~/ezgrubconfig && flutter create --platforms=linux --project-name ezgrubconfig .
```

Expected: `All done!` y mensaje de que se creó el proyecto.

- [ ] **Step 2: Verificar que compila y los tests del template pasan**

```bash
cd ~/ezgrubconfig && flutter test && flutter build linux
```

Expected: `All tests passed!` y `✓ Built build/linux/x64/release/bundle/ezgrubconfig` (o similar).

- [ ] **Step 3: Commit**

```bash
cd ~/ezgrubconfig && git add -A && git commit -m "chore: scaffold Flutter para Linux"
```

---

### Task 2: Modelo y parser de `grub.cfg`

**Files:**
- Create: `lib/grub_config.dart`
- Create: `test/fixtures/grub.cfg`
- Create: `test/grub_config_test.dart`

**Interfaces:**
- Consumes: nada.
- Produces (los Tasks 4 y 6 dependen de esto):
  - `enum GrubEntryType { kernel, otros, custom }`
  - `class GrubEntry { String title; String id; GrubEntryType type; List<GrubEntry> children; GrubEntry({required this.title, required this.id, required this.type, List<GrubEntry>? children}); bool get isSubmenu; }`
  - `List<GrubEntry> parseGrubCfg(String content)` — parser línea a línea con conteo de llaves; las líneas `function`/`if` del header no afectan (los `}` huérfanos se ignoran si no hay entrada abierta).
  - `String grubTitle(String line)` — primera cadena entre comillas simples de la línea.
  - `String grubEntryId(String line)` — valor de `$menuentry_id_option '...'` o `--id '...'`; fallback al título.

- [ ] **Step 1: Crear fixture `test/fixtures/grub.cfg`**

```
if [ "${grub_platform}" = "efi" ]; then
	load_efi_vars
fi

function load_video {
  insmod efi_gop
  insmod efi_uga
}

submenu 'CachyOS Linux' --class gnu_linux --class os $menuentry_id_option 'gnulinux-advanced-uuid1' {
	menuentry 'CachyOS Linux, with Linux linux-cachyos' --class gnu_linux --class os $menuentry_id_option 'gnulinux-linux-cachyos-advanced-uuid1' {
		load_video
		echo	'Loading Linux linux-cachyos ...'
	}
	menuentry 'CachyOS Linux, with Linux linux-cachyos-lts' --class gnu_linux --class os $menuentry_id_option 'gnulinux-linux-cachyos-lts-advanced-uuid1' {
		echo	'Loading Linux linux-cachyos-lts ...'
	}
}

menuentry 'Windows Boot Manager (on /dev/nvme0n1p1)' --class windows --class os $menuentry_id_option 'osprober-chain-uuid2' {
	insmod part_gpt
}
```

- [ ] **Step 2: Escribir los tests fallidos en `test/grub_config_test.dart`** (reemplaza el contenido generado por `flutter create`; se añadirán más tests en Tasks 3 y 4 al mismo archivo)

```dart
import 'dart:io';

import 'package:ezgrubconfig/grub_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cfg = File('test/fixtures/grub.cfg').readAsStringSync();

  test('parseGrubCfg extrae jerarquía e ids', () {
    final entries = parseGrubCfg(cfg);
    expect(entries, hasLength(2));
    expect(entries[0].title, 'CachyOS Linux');
    expect(entries[0].id, 'gnulinux-advanced-uuid1');
    expect(entries[0].children, hasLength(2));
    expect(entries[0].children[0].id, 'gnulinux-linux-cachyos-advanced-uuid1');
    expect(entries[1].title, startsWith('Windows Boot Manager'));
    expect(entries[1].id, 'osprober-chain-uuid2');
    expect(entries[0].isSubmenu, isTrue);
    expect(entries[1].isSubmenu, isFalse);
  });

  test('las funciones shell del header no confunden al parser', () {
    // el `}` de `function load_video` no debe cerrar nada
    final entries = parseGrubCfg(cfg);
    expect(entries, hasLength(2));
  });

  test('clasifica kernel vs otros', () {
    final entries = parseGrubCfg(cfg);
    expect(entries[0].children[0].type, GrubEntryType.kernel);
    expect(entries[0].children[1].type, GrubEntryType.kernel);
    expect(entries[1].type, GrubEntryType.otros);
  });

  test('grubTitle y grubEntryId', () {
    const line =
        "menuentry 'Win (on /dev/sda1)' --class os \$menuentry_id_option 'osprober-x' {";
    expect(grubTitle(line), 'Win (on /dev/sda1)');
    expect(grubEntryId(line), 'osprober-x');
    expect(grubEntryId("menuentry 'Solo titulo' --id 'mi-id' {"), 'mi-id');
    expect(grubEntryId("menuentry 'Solo titulo' {"), 'Solo titulo');
  });
}
```

- [ ] **Step 3: Ejecutar y verificar que falla**

Run: `cd ~/ezgrubconfig && flutter test test/grub_config_test.dart`
Expected: FAIL de compilación — `Error: Couldn't resolve the package 'ezgrubconfig'` no (el paquete existe desde Task 1), sino `Error: 'parseGrubCfg' isn't defined`.

- [ ] **Step 4: Implementar `lib/grub_config.dart`**

```dart
// ponytail: parser línea a línea; un título con comilla simple escapada (\')
// se trunca. Los grub.cfg reales de Arch/CachyOS rara vez lo usan.
enum GrubEntryType { kernel, otros, custom }

class GrubEntry {
  String title;
  String id;
  GrubEntryType type;
  List<GrubEntry> children;

  GrubEntry({
    required this.title,
    required this.id,
    required this.type,
    List<GrubEntry>? children,
  }) : children = children ?? [];

  bool get isSubmenu => children.isNotEmpty;
}

String grubTitle(String line) {
  return RegExp("'([^']*)'").firstMatch(line)?.group(1) ?? line.trim();
}

String grubEntryId(String line) {
  return RegExp(r"\$menuentry_id_option '([^']+)'").firstMatch(line)?.group(1) ??
      RegExp(r"--id '([^']+)'").firstMatch(line)?.group(1) ??
      grubTitle(line);
}

GrubEntryType _classify(String line) {
  final t = grubTitle(line).toLowerCase();
  return t.contains('linux') ? GrubEntryType.kernel : GrubEntryType.otros;
}

List<GrubEntry> parseGrubCfg(String content) {
  final root = <GrubEntry>[];
  final stack = <List<GrubEntry>>[root];
  final open = <GrubEntry>[];

  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('menuentry ') || line.startsWith('submenu ')) {
      final entry = GrubEntry(
        title: grubTitle(line),
        id: grubEntryId(line),
        type: _classify(line),
      );
      stack.last.add(entry);
      open.add(entry);
      stack.add(entry.children);
    } else if (line.startsWith('}') && open.isNotEmpty) {
      open.removeLast();
      stack.removeLast();
    }
  }
  return root;
}
```

- [ ] **Step 5: Ejecutar y verificar que pasan**

Run: `cd ~/ezgrubconfig && flutter test test/grub_config_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
cd ~/ezgrubconfig && git add lib/grub_config.dart test/ && git commit -m "feat: parser de grub.cfg con modelo GrubEntry"
```

---

### Task 3: Lector/escritor de `/etc/default/grub`

**Files:**
- Modify: `lib/grub_config.dart` (añadir clase `DefaultGrub`)
- Modify: `test/grub_config_test.dart`
- Create: `test/fixtures/default_grub`

**Interfaces:**
- Consumes: nada del Task 2 (misma librería, clases independientes).
- Produces (Task 6 depende de esto):
  - `class DefaultGrub { DefaultGrub(this.content); final String content; String? valueOf(String key); String withValues(Map<String, String> values); }`
  - `valueOf` devuelve el valor sin comillas; `withValues` reemplaza solo las claves dadas conservando el estilo de comillas existente, y el resto del archivo queda intacto.

- [ ] **Step 1: Crear fixture `test/fixtures/default_grub`**

```
GRUB_DEFAULT='gnulinux-advanced-uuid1>gnulinux-linux-cachyos-lts-advanced-uuid1'
GRUB_TIMEOUT='5'
GRUB_TIMEOUT_STYLE=menu
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash clocksource=tsc tsc=reliable"
GRUB_CMDLINE_LINUX=""
```

(sin `\n` final en la última línea, como el archivo real)

- [ ] **Step 2: Añadir tests fallidos** (dentro de `main()` de `test/grub_config_test.dart`)

```dart
  final defaultGrubRaw =
      File('test/fixtures/default_grub').readAsStringSync();

  test('DefaultGrub.valueOf no confunde claves con prefijo común', () {
    final dg = DefaultGrub(defaultGrubRaw);
    expect(dg.valueOf('GRUB_TIMEOUT'), '5'); // NO 'menu' (STYLE comparte prefijo)
    expect(dg.valueOf('GRUB_TIMEOUT_STYLE'), 'menu');
    expect(
        dg.valueOf('GRUB_DEFAULT'),
        'gnulinux-advanced-uuid1>'
        'gnulinux-linux-cachyos-lts-advanced-uuid1');
    expect(dg.valueOf('GRUB_INEXISTENTE'), isNull);
  });

  test('withValues cambia solo las claves pedidas', () {
    final result = DefaultGrub(defaultGrubRaw)
        .withValues({'GRUB_DEFAULT': 'nuevo-id', 'GRUB_TIMEOUT': '3'});
    final dg = DefaultGrub(result);
    expect(dg.valueOf('GRUB_DEFAULT'), 'nuevo-id');
    expect(dg.valueOf('GRUB_TIMEOUT'), '3');
    expect(dg.valueOf('GRUB_TIMEOUT_STYLE'), 'menu');
    expect(dg.valueOf('GRUB_CMDLINE_LINUX_DEFAULT'),
        'quiet splash clocksource=tsc tsc=reliable');
    // líneas no tocadas, byte a byte
    String? lineOf(String s, String key) => s
        .split('\n')
        .firstWhere((l) => l.startsWith('$key='), orElse: () => '');
    expect(lineOf(result, 'GRUB_CMDLINE_LINUX_DEFAULT'),
        lineOf(defaultGrubRaw, 'GRUB_CMDLINE_LINUX_DEFAULT'));
    expect(lineOf(result, 'GRUB_CMDLINE_LINUX'),
        lineOf(defaultGrubRaw, 'GRUB_CMDLINE_LINUX'));
  });

  test('withValues respeta las comillas dobles existentes', () {
    final result = DefaultGrub(defaultGrubRaw)
        .withValues({'GRUB_CMDLINE_LINUX_DEFAULT': 'quiet'});
    expect(result, contains('GRUB_CMDLINE_LINUX_DEFAULT="quiet"'));
    expect(DefaultGrub(result).valueOf('GRUB_CMDLINE_LINUX_DEFAULT'), 'quiet');
  });
```

- [ ] **Step 3: Ejecutar y verificar que falla**

Run: `cd ~/ezgrubconfig && flutter test test/grub_config_test.dart`
Expected: FAIL — `Error: 'DefaultGrub' isn't defined`.

- [ ] **Step 4: Añadir `DefaultGrub` a `lib/grub_config.dart`**

```dart
class DefaultGrub {
  final String content;

  DefaultGrub(this.content);

  String? valueOf(String key) {
    for (final line in content.split('\n')) {
      final m = RegExp('^${RegExp.escape(key)}=(.*)\$').firstMatch(line.trim());
      if (m == null) continue;
      var v = m.group(1)!;
      if (v.length >= 2 &&
          ((v.startsWith("'") && v.endsWith("'")) ||
              (v.startsWith('"') && v.endsWith('"')))) {
        v = v.substring(1, v.length - 1);
      }
      return v;
    }
    return null;
  }

  String withValues(Map<String, String> values) {
    final lines = content.split('\n');
    final pending = Map<String, String>.of(values);
    for (var i = 0; i < lines.length; i++) {
      final m =
          RegExp('^([A-Za-z_][A-Za-z0-9_]*)=').firstMatch(lines[i]);
      if (m == null) continue;
      final key = m.group(1)!;
      if (!pending.containsKey(key)) continue;
      final rest = lines[i].substring(key.length + 1);
      final quote =
          rest.isNotEmpty && (rest.startsWith("'") || rest.startsWith('"'))
              ? rest[0]
              : '';
      lines[i] = quote.isEmpty
          ? '$key=${pending[key]}'
          : "$key=$quote${pending[key]}$quote";
      pending.remove(key);
    }
    for (final e in pending.entries) {
      lines.add("${e.key}='${e.value}'");
    }
    return lines.join('\n');
  }
}
```

- [ ] **Step 5: Ejecutar y verificar que pasan**

Run: `cd ~/ezgrubconfig && flutter test test/grub_config_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
cd ~/ezgrubconfig && git add lib/grub_config.dart test/ && git commit -m "feat: lectura/escritura de /etc/default/grub"
```

---

### Task 4: CRUD de entradas custom (`40_custom`)

**Files:**
- Create: `lib/custom_entries.dart`
- Modify: `test/grub_config_test.dart`
- Create: `test/fixtures/40_custom`

**Interfaces:**
- Consumes: `grubTitle`/`grubEntryId` de `lib/grub_config.dart` (Task 2).
- Produces (Task 6 depende de esto):
  - `class CustomEntry { String title; String id; String body; CustomEntry({required this.title, required this.id, required this.body}); }`
  - `class CustomEntries { CustomEntries(this.header, this.entries); String header; List<CustomEntry> entries; static CustomEntries parse(String content); String serialize(); static String? validate(CustomEntry e); }`
  - `validate` devuelve `null` si la entrada es válida, o un mensaje de error en español.

- [ ] **Step 1: Crear fixture `test/fixtures/40_custom`**

```
#!/bin/sh
exec tail -n +3 $0
# Entradas personalizadas de EZGrubConfig
menuentry 'Rescue' --id 'rescue-1' {
	linux /boot/vmlinuz-rescue root=UUID=rescue rw
	initrd /boot/initramfs-rescue.img
}
```

- [ ] **Step 2: Añadir tests fallidos** (en `test/grub_config_test.dart`, nuevo import `package:ezgrubconfig/custom_entries.dart`)

```dart
  final customRaw = File('test/fixtures/40_custom').readAsStringSync();

  test('CustomEntries.parse extrae header y entradas', () {
    final ce = CustomEntries.parse(customRaw);
    expect(ce.header, contains('exec tail -n +3'));
    expect(ce.header, contains('# Entradas personalizadas'));
    expect(ce.entries, hasLength(1));
    expect(ce.entries[0].title, 'Rescue');
    expect(ce.entries[0].id, 'rescue-1');
    expect(ce.entries[0].body, contains('linux /boot/vmlinuz-rescue'));
    expect(ce.entries[0].body, contains('initrd /boot/initramfs-rescue.img'));
  });

  test('add/edit/delete via serialize redondea', () {
    final ce = CustomEntries.parse(customRaw);
    ce.entries.add(
        CustomEntry(title: 'Nuevo', id: 'nuevo-1', body: 'linux /vmlinuz'));
    final re = CustomEntries.parse(ce.serialize());
    expect(re.entries, hasLength(2));
    expect(re.header, ce.header);
    expect(re.entries[1].title, 'Nuevo');

    re.entries[0].body = 'linux /boot/vmlinuz-rescue2';
    expect(CustomEntries.parse(re.serialize()).entries[0].body,
        contains('vmlinuz-rescue2'));

    re.entries.removeAt(1);
    expect(CustomEntries.parse(re.serialize()).entries, hasLength(1));
  });

  test('un archivo sin menuentries se conserva tal cual', () {
    final ce = CustomEntries.parse(customRaw);
    final vacio = CustomEntries.parse('#!/bin/sh\nexec tail -n +3 \$0\n');
    expect(vacio.entries, isEmpty);
    expect(vacio.serialize(), '#!/bin/sh\nexec tail -n +3 \$0\n');
    expect(ce.serialize(), isNotEmpty);
  });

  test('validate detecta título vacío y llaves desbalanceadas', () {
    expect(
        CustomEntries.validate(
            CustomEntry(title: ' ', id: 'x', body: 'linux /vmlinuz')),
        isNotNull);
    expect(
        CustomEntries.validate(
            CustomEntry(title: 'T', id: 'x', body: 'search {x')),
        isNotNull);
    expect(
        CustomEntries.validate(
            CustomEntry(title: 'T', id: 'x', body: 'echo ${var}')),
        isNull); // ${var} balancea a 0
    expect(
        CustomEntries.validate(
            CustomEntry(title: 'T', id: 'x', body: 'linux /vmlinuz')),
        isNull);
  });
```

- [ ] **Step 3: Ejecutar y verificar que falla**

Run: `cd ~/ezgrubconfig && flutter test test/grub_config_test.dart`
Expected: FAIL — `Error: 'CustomEntries' isn't defined`.

- [ ] **Step 4: Implementar `lib/custom_entries.dart`**

```dart
import 'grub_config.dart';

class CustomEntry {
  String title;
  String id;
  String body; // líneas entre { y }, sin las llaves

  CustomEntry({required this.title, required this.id, required this.body});
}

class CustomEntries {
  String header; // todo lo anterior al primer menuentry (shebang, exec tail, comentarios)
  List<CustomEntry> entries;

  CustomEntries(this.header, this.entries);

  /// Extrae las entradas (bloques `menuentry ... }`) y deja el resto en [header].
  static CustomEntries parse(String content) {
    final lines = content.split('\n');
    final first =
        lines.indexWhere((l) => l.trimLeft().startsWith('menuentry'));
    if (first == -1) {
      return CustomEntries(
          content.endsWith('\n') ? content : '$content\n', []);
    }
    final header = lines.take(first).join('\n');
    final entries = <CustomEntry>[];
    var i = first;
    while (i < lines.length) {
      final line = lines[i].trim();
      if (!line.startsWith('menuentry')) {
        i++;
        continue;
      }
      final openLine = line;
      var depth = '{'.allMatches(openLine).length;
      final body = <String>[];
      i++;
      while (i < lines.length && depth > 0) {
        depth += '{'.allMatches(lines[i]).length;
        depth -= '}'.allMatches(lines[i]).length;
        if (depth > 0) body.add(lines[i]);
        i++;
      }
      entries.add(CustomEntry(
          title: grubTitle(openLine),
          id: grubEntryId(openLine),
          body: body.join('\n')));
    }
    return CustomEntries(header, entries);
  }

  String serialize() {
    final b = StringBuffer(header.isEmpty
        ? ''
        : header.endsWith('\n')
            ? header
            : '$header\n');
    for (final e in entries) {
      final safeTitle = e.title.replaceAll("'", r"\'");
      b.writeln("menuentry '$safeTitle' --id '${e.id}' {");
      if (e.body.isNotEmpty) b.writeln(e.body);
      b.writeln('}');
    }
    return b.toString();
  }

  /// null si es válida; mensaje de error en caso contrario.
  static String? validate(CustomEntry e) {
    if (e.title.trim().isEmpty) return 'El título no puede estar vacío';
    if (e.id.trim().isEmpty) return 'El id no puede estar vacío';
    var depth = 0;
    for (final ch in e.body.runes) {
      if (ch == 0x7B) depth++;
      if (ch == 0x7D) depth--;
      if (depth < 0) return 'Llaves desbalanceadas en el cuerpo';
    }
    if (depth != 0) return 'Llaves desbalanceadas en el cuerpo';
    return null;
  }
}
```

- [ ] **Step 5: Ejecutar y verificar que pasan**

Run: `cd ~/ezgrubconfig && flutter test test/grub_config_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
cd ~/ezgrubconfig && git add lib/custom_entries.dart test/ && git commit -m "feat: CRUD de entradas custom en 40_custom"
```

---

### Task 5: Capa pkexec (lectura/escritura root, backup, regenerar, restaurar)

**Files:**
- Create: `lib/pkexec.dart`

**Interfaces:**
- Consumes: nada.
- Produces (Task 6 depende de esto):
  - `class RunResult { final int exitCode; final String stdout; final String stderr; RunResult(this.exitCode, this.stdout, this.stderr); bool get ok; }`
  - `class PkexecCancelled implements Exception { final String message; PkexecCancelled(this.message); String toString(); }`
  - `Future<RunResult> runRoot(List<String> args, {String? input})` — lanza `pkexec args...`; con `input` lo escribe por stdin. Lanza `PkexecCancelled` si polkit reporta cancelación/no autorización.
  - `Future<String> readRoot(String path)` — `pkexec cat`.
  - `Future<String> writeRoot(String path, String content)` — backup `<path>.bak-YYYYMMDD-HHMMSS` y luego `pkexec tee`; **devuelve la ruta del backup**.
  - `Future<RunResult> regenerateGrub()` — `pkexec grub-mkconfig -o /boot/grub/grub.cfg`.
  - `Future<RunResult> restoreBackups(Map<String, String> backups)` — `pkexec sh -c 'cp -a backup original && ...'`.

Sin tests unitarios: es un envoltorio de `Process.run` (decisión de la spec). La verificación es que `flutter analyze` y `flutter build linux` pasen.

- [ ] **Step 1: Implementar `lib/pkexec.dart`**

```dart
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
```

- [ ] **Step 2: Verificar análisis y compilación**

Run: `cd ~/ezgrubconfig && flutter analyze && flutter build linux`
Expected: `No issues found!` y build OK.

- [ ] **Step 3: Commit**

```bash
cd ~/ezgrubconfig && git add lib/pkexec.dart && git commit -m "feat: capa pkexec con backups y restauración"
```

---

### Task 6: UI — pantalla única con las tres secciones + Aplicar

**Files:**
- Modify: `lib/main.dart` (reemplazo completo del template)
- Delete: `test/widget_test.dart` (testea el counter del template que ya no existe)

**Interfaces:**
- Consumes: `parseGrubCfg`, `GrubEntry`, `GrubEntryType`, `DefaultGrub` (Task 2/3); `CustomEntries`, `CustomEntry` (Task 4); `readRoot`, `writeRoot`, `regenerateGrub`, `restoreBackups`, `RunResult`, `PkexecCancelled` (Task 5).
- Produces: app completa. Verificación: `flutter test` verde, `flutter analyze` limpio, `flutter build linux` OK, smoke manual.

- [ ] **Step 1: Eliminar el test del template**

```bash
cd ~/ezgrubconfig && rm test/widget_test.dart
```

- [ ] **Step 2: Reemplazar `lib/main.dart`**

```dart
import 'dart:io';

import 'package:flutter/material.dart';

import 'custom_entries.dart';
import 'grub_config.dart';
import 'pkexec.dart';

void main() {
  runApp(const EzGrubConfigApp());
}

class EzGrubConfigApp extends StatelessWidget {
  const EzGrubConfigApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EZGrubConfig',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const HomePage(),
    );
  }
}

class _MenuPath {
  final GrubEntry entry;
  final String defaultPath; // valor para GRUB_DEFAULT: 'id' o 'submenuId>id'

  _MenuPath(this.entry, this.defaultPath);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<_MenuPath> _menuPaths = [];
  List<CustomEntry> _custom = [];
  String _customHeader = '';
  String _originalDefaultGrub = '';
  String? _selected;
  String _timeout = '5';
  String _timeoutStyle = 'menu';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      _originalDefaultGrub = File('/etc/default/grub').readAsStringSync();
      final dg = DefaultGrub(_originalDefaultGrub);
      final def = dg.valueOf('GRUB_DEFAULT') ?? '0';

      final ce = CustomEntries.parse(
          File('/etc/grub.d/40_custom').readAsStringSync());
      _customHeader = ce.header;
      _custom = ce.entries
          .map((e) =>
              CustomEntry(title: e.title, id: e.id, body: e.body))
          .toList();

      final cfg = await readRoot('/boot/grub/grub.cfg');
      final paths = <_MenuPath>[];
      void walk(List<GrubEntry> entries, String? parent) {
        for (final e in entries) {
          final p = parent == null ? e.id : '$parent>${e.id}';
          if (e.children.isEmpty) {
            paths.add(_MenuPath(e, p));
          } else {
            walk(e.children, p);
          }
        }
      }

      walk(parseGrubCfg(cfg), null);
      for (final e in _custom) {
        paths.add(_MenuPath(
            GrubEntry(
                title: e.title, id: e.id, type: GrubEntryType.custom),
            e.id));
      }

      if (!mounted) return;
      setState(() {
        _timeout = dg.valueOf('GRUB_TIMEOUT') ?? '5';
        _timeoutStyle = dg.valueOf('GRUB_TIMEOUT_STYLE') ?? 'menu';
        _menuPaths = paths;
        _selected = _resolveDefault(def, paths);
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error cargando la configuración: $err')));
    }
  }

  /// Acepta el path 'submenu>entrada' o un índice numérico (GRUB_DEFAULT=0).
  String? _resolveDefault(String def, List<_MenuPath> paths) {
    final numeric = int.tryParse(def);
    if (numeric != null) {
      return (numeric >= 0 && numeric < paths.length)
          ? paths[numeric].defaultPath
          : null;
    }
    for (final p in paths) {
      if (p.defaultPath == def) return p.defaultPath;
    }
    return null;
  }

  Future<void> _apply() async {
    final messenger = ScaffoldMessenger.of(context);
    if (int.tryParse(_timeout) == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('El tiempo de espera debe ser un número '
              '(puede ser negativo para esperar indefinido).')));
      return;
    }
    try {
      final newDefault = DefaultGrub(_originalDefaultGrub).withValues({
        'GRUB_DEFAULT': _selected ?? '0',
        'GRUB_TIMEOUT': _timeout,
        'GRUB_TIMEOUT_STYLE': _timeoutStyle,
      });
      final backups = <String, String>{
        '/etc/default/grub':
            await writeRoot('/etc/default/grub', newDefault),
        '/etc/grub.d/40_custom': await writeRoot('/etc/grub.d/40_custom',
            CustomEntries(_customHeader, _custom).serialize()),
      };
      final r = await regenerateGrub();
      if (!r.ok) {
        if (!mounted) return;
        _regenErrorDialog(r, backups);
        return;
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Configuración aplicada'),
          content: SingleChildScrollView(
            child: Text(r.stdout.isEmpty ? '(sin salida)' : r.stdout),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
      await _reload();
    } on PkexecCancelled {
      messenger.showSnackBar(const SnackBar(
          content:
              Text('Autenticación cancelada, no se cambió nada.')));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Error: $err')));
    }
  }

  void _regenErrorDialog(RunResult r, Map<String, String> backups) {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('grub-mkconfig falló'),
        content: SingleChildScrollView(
          child: Text(r.stderr.isEmpty ? r.stdout : r.stderr),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await restoreBackups(backups);
              messenger.showSnackBar(const SnackBar(
                  content: Text('Backups restaurados.')));
              await _reload();
            },
            child: const Text('Restaurar backups'),
          ),
        ],
      ),
    );
  }

  Future<void> _editEntry([CustomEntry? existing]) async {
    final title = TextEditingController(text: existing?.title ?? '');
    final id = TextEditingController(
        text: existing?.id ?? 'custom-${_custom.length + 1}');
    final body = TextEditingController(text: existing?.body ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title:
            Text(existing == null ? 'Nueva entrada' : 'Editar entrada'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration:
                    const InputDecoration(labelText: 'Título'),
              ),
              TextField(
                controller: id,
                decoration: const InputDecoration(
                    labelText: 'Id (menuentry --id)'),
              ),
              TextField(
                controller: body,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Comandos (linux / initrd / …)',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final entry =
        CustomEntry(title: title.text, id: id.text, body: body.text);
    final err = CustomEntries.validate(entry);
    if (err != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() {
      final i = existing == null ? -1 : _custom.indexOf(existing);
      if (i >= 0) {
        _custom[i] = entry;
      } else {
        _custom.add(entry);
      }
    });
  }

  String _typeLabel(GrubEntryType t) =>
      switch (t) { GrubEntryType.kernel => 'Kernel', GrubEntryType.otros => 'Otro', GrubEntryType.custom => 'Custom' };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EZGrubConfig'),
        actions: [
          IconButton(
            tooltip: 'Recargar',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _loading ? null : _apply,
              child: const Text('Aplicar'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _entriesCard(),
                _settingsCard(),
                _customCard(),
              ],
            ),
    );
  }

  Widget _entriesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Entradas del menú',
                style: Theme.of(context).textTheme.titleMedium),
            const Text('Toca una entrada para hacerla la predeterminada.'),
            for (final p in _menuPaths)
              RadioListTile<String>(
                value: p.defaultPath,
                groupValue: _selected,
                onChanged: (v) => setState(() => _selected = v),
                title: Text(p.entry.title),
                subtitle: Text(p.defaultPath),
                secondary: Chip(label: Text(_typeLabel(p.entry.type))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _settingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ajustes',
                style: Theme.of(context).textTheme.titleMedium),
            Row(
              children: [
                const Expanded(
                    child: Text('Tiempo de espera del menú (s):')),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: _timeout,
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _timeout = v,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const Expanded(child: Text('Estilo del menú:')),
                DropdownButton<String>(
                  value: _timeoutStyle,
                  items: const [
                    DropdownMenuItem(
                        value: 'menu', child: Text('Mostrar menú')),
                    DropdownMenuItem(
                        value: 'hidden', child: Text('Oculto')),
                  ],
                  onChanged: (v) =>
                      setState(() => _timeoutStyle = v ?? 'menu'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _customCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                      'Entradas custom (/etc/grub.d/40_custom)',
                      style:
                          Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Añadir entrada',
                  onPressed: () => _editEntry(),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            for (final e in _custom)
              ListTile(
                title: Text(e.title),
                subtitle: Text(e.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Editar',
                      onPressed: () => _editEntry(e),
                      icon: const Icon(Icons.edit),
                    ),
                    IconButton(
                      tooltip: 'Eliminar',
                      onPressed: () =>
                          setState(() => _custom.remove(e)),
                      icon: const Icon(Icons.delete),
                    ),
                  ],
                ),
              ),
            if (_custom.isEmpty)
              const Text('Sin entradas custom.'),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Verificar todo**

Run: `cd ~/ezgrubconfig && flutter test && flutter analyze && flutter build linux`
Expected: `All tests passed!`, `No issues found!`, build OK. (Si `RadioListTile` marca deprecación de `groupValue` según tu versión de Flutter, es un warning del analyzer, no un error de build — déjalo pasar o usa `RadioGroup` si el analyzer lo sugiere.)

- [ ] **Step 4: Commit**

```bash
cd ~/ezgrubconfig && git add -A && git commit -m "feat: UI principal — default, ajustes y entradas custom"
```

---

## Verificación final (manual, en la máquina real)

Ejecutar `cd ~/ezgrubconfig && flutter run -d linux` y comprobar:

1. La lista muestra los kernels reales (subsubmenu de CachyOS), Windows/os-prober y las entradas custom como "Custom".
2. Tocar otra entrada → Aplicar → polkit pide contraseña → snackbar OK → la app recarga con la nueva default resaltada. Verificar con `grep GRUB_DEFAULT /etc/default/grub` y que `/boot/grub/grub.cfg` tenga `set default="..."` con el nuevo valor.
3. Cambiar timeout a 10 → Aplicar → `grep GRUB_TIMEOUT /etc/default/grub` muestra 10.
4. Crear una entrada custom de prueba → Aplicar → `grep menuentry /etc/grub.d/40_custom` la muestra; borrarla y Aplicar de nuevo.
5. Cancelar el diálogo de polkit → snackbar "cancelada", sin cambios.
6. Los backups quedan en `/etc/default/grub.bak-*` y `/etc/grub.d/40_custom.bak-*`.

**Cuidado:** esto modifica el GRUB real de la máquina. Probar el flujo de restauración (romper a propósito una entrada custom con llaves desbalanceadas… no se puede: `validate` lo bloquea antes; en su lugar verificar los `.bak` con `diff`) antes de reiniciar.
