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
    final first = lines.indexWhere((l) => l.trimLeft().startsWith('menuentry'));
    if (first == -1) {
      return CustomEntries(content.endsWith('\n') ? content : '$content\n', []);
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
      entries.add(
        CustomEntry(
          title: grubTitle(openLine),
          id: grubEntryId(openLine),
          body: body.join('\n'),
        ),
      );
    }
    return CustomEntries(header, entries);
  }

  String serialize() {
    final b = StringBuffer(
      header.isEmpty
          ? ''
          : header.endsWith('\n')
          ? header
          : '$header\n',
    );
    for (final e in entries) {
      // GRUB no tiene escapes en cadenas entre comillas simples (un \'
      // literal es syntax error); validate() rechaza el ' antes de llegar aquí.
      b.writeln("menuentry '${e.title}' --id '${e.id}' {");
      if (e.body.isNotEmpty) b.writeln(e.body);
      b.writeln('}');
    }
    return b.toString();
  }

  /// null si es válida; mensaje de error en caso contrario.
  /// [takenIds] son ids ya usados por otras entradas (unicidad).
  static String? validate(
    CustomEntry e, {
    Iterable<String> takenIds = const [],
  }) {
    if (e.title.trim().isEmpty) return 'El título no puede estar vacío';
    if (e.title.contains("'")) {
      return 'El título no puede contener comillas simples '
          "(GRUB no permite escaparlas)";
    }
    if (e.id.trim().isEmpty) return 'El id no puede estar vacío';
    if (e.id.contains("'")) {
      return 'El id no puede contener comillas simples '
          '(GRUB no permite escaparlas)';
    }
    if (e.id.contains('>')) {
      return "El id no puede contener '>' (se usa para separar "
          'submenus en GRUB_DEFAULT)';
    }
    if (e.id.contains('\n') || e.id.contains('\r')) {
      return 'El id no puede contener saltos de línea';
    }
    if (takenIds.contains(e.id)) {
      return 'Ya existe una entrada con el id "${e.id}"';
    }
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
