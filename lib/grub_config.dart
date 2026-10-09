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
  return RegExp(r"\$menuentry_id_option '([^']+)'")
          .firstMatch(line)
          ?.group(1) ??
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

/// Resuelve un valor de GRUB_DEFAULT (índice numérico o ruta
/// 'submenu>entrada') a la ruta completa de la hoja que GRUB arrancaría,
/// o null si no coincide con ninguna entrada.
/// Un índice numérico cuenta entradas de NIVEL SUPERIOR (un submenu es UNA
/// entrada, como hace el propio GRUB); si apunta a un submenu, resuelve a
/// su primer descendiente hoja.
String? resolveGrubDefault(String def, List<GrubEntry> entries) {
  final numeric = int.tryParse(def);
  if (numeric != null) {
    if (numeric < 0 || numeric >= entries.length) return null;
    return _firstLeafPath(entries[numeric], entries[numeric].id);
  }
  String? walk(List<GrubEntry> es, String? parent) {
    for (final e in es) {
      final p = parent == null ? e.id : '$parent>${e.id}';
      if (p == def) {
        return e.children.isEmpty ? p : _firstLeafPath(e, p);
      }
      final r = walk(e.children, p);
      if (r != null) return r;
    }
    return null;
  }

  return walk(entries, null);
}

String _firstLeafPath(GrubEntry e, String path) {
  while (e.children.isNotEmpty) {
    e = e.children.first;
    path = '$path>${e.id}';
  }
  return path;
}

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
      final m = RegExp('^([A-Za-z_][A-Za-z0-9_]*)=').firstMatch(lines[i]);
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
