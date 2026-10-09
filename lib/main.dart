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
  List<_MenuPath> _generatedPaths = []; // hojas de grub.cfg (sin customs)
  List<CustomEntry> _custom = [];
  String _customHeader = '';
  String _originalDefaultGrub = '';
  String _originalDefault = '0';
  String? _selected;
  String _timeout = '5';
  String _timeoutStyle = 'menu';
  bool _loading = true;
  bool _applying = false;

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
        File('/etc/grub.d/40_custom').readAsStringSync(),
      );
      _customHeader = ce.header;
      _custom = ce.entries
          .map((e) => CustomEntry(title: e.title, id: e.id, body: e.body))
          .toList();

      final cfg = await readRoot('/boot/grub/grub.cfg');
      final topLevel = parseGrubCfg(cfg);
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

      walk(topLevel, null);

      if (!mounted) return;
      setState(() {
        _timeout = dg.valueOf('GRUB_TIMEOUT') ?? '5';
        _timeoutStyle = dg.valueOf('GRUB_TIMEOUT_STYLE') ?? 'menu';
        _generatedPaths = paths;
        _syncMenuPaths();
        // GRUB cuenta índices numéricos a nivel superior (un submenu es UNA
        // entrada); las customs van al final del menú generado, como el
        // contenido de 40_custom en el grub.cfg regenerado.
        _selected = resolveGrubDefault(def, [...topLevel, ..._customEntries()]);
        _originalDefault = def;
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error cargando la configuración: $err')),
      );
    }
  }

  List<GrubEntry> _customEntries() => [
    for (final e in _custom)
      GrubEntry(title: e.title, id: e.id, type: GrubEntryType.custom),
  ];

  /// Recalcula las rutas mostradas tras cambiar _custom y descarta la
  /// selección si su entrada ya no existe.
  void _syncMenuPaths() {
    _menuPaths = [
      ..._generatedPaths,
      ..._customEntries().map((e) => _MenuPath(e, e.id)),
    ];
    if (_selected != null &&
        !_menuPaths.any((p) => p.defaultPath == _selected)) {
      _selected = null;
    }
  }

  Future<void> _apply() async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      await _applyInner();
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _applyInner() async {
    final messenger = ScaffoldMessenger.of(context);
    if (int.tryParse(_timeout) == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'El tiempo de espera debe ser un número '
            '(puede ser negativo para esperar indefinido).',
          ),
        ),
      );
      return;
    }
    final newDefault = DefaultGrub(_originalDefaultGrub).withValues({
      'GRUB_DEFAULT': _selected ?? _originalDefault,
      'GRUB_TIMEOUT': _timeout,
      'GRUB_TIMEOUT_STYLE': _timeoutStyle,
    });
    final newCustom = CustomEntries(_customHeader, _custom).serialize();
    final backups = <String, String>{};
    try {
      backups['/etc/default/grub'] = await writeRoot(
        '/etc/default/grub',
        newDefault,
      );
      backups['/etc/grub.d/40_custom'] = await writeRoot(
        '/etc/grub.d/40_custom',
        newCustom,
      );
    } on PkexecCancelled {
      if (backups.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Autenticación cancelada, no se cambió nada.'),
          ),
        );
      } else {
        _partialWriteDialog(
          messenger,
          backups,
          'Autenticación cancelada a mitad de la aplicación.',
        );
      }
      return;
    } catch (err) {
      if (backups.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text('Error: $err')));
      } else {
        _partialWriteDialog(messenger, backups, 'Error: $err');
      }
      return;
    }
    RunResult r;
    try {
      r = await regenerateGrub();
    } on PkexecCancelled {
      _partialWriteDialog(
        messenger,
        backups,
        'Autenticación cancelada durante la regeneración de grub.cfg.',
      );
      return;
    } catch (err) {
      _partialWriteDialog(
        messenger,
        backups,
        'Error regenerando grub.cfg: $err',
      );
      return;
    }
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
              await _restoreBackupsGuarded(messenger, backups);
            },
            child: const Text('Restaurar backups'),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreBackupsGuarded(
    ScaffoldMessengerState messenger,
    Map<String, String> backups,
  ) async {
    try {
      await restoreBackups(backups);
      messenger.showSnackBar(
        const SnackBar(content: Text('Backups restaurados.')),
      );
      await _reload();
    } on PkexecCancelled {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Autenticación cancelada, los archivos quedaron sin restaurar.',
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text('Error restaurando los backups: $err')),
      );
    }
  }

  void _partialWriteDialog(
    ScaffoldMessengerState messenger,
    Map<String, String> backups,
    String detalle,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No se pudo aplicar completamente'),
        content: SingleChildScrollView(
          child: Text(
            '$detalle\n\n'
            'Algunos archivos ya quedaron escritos. '
            'Puedes restaurar los backups.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _restoreBackupsGuarded(messenger, backups);
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
      text: existing?.id ?? 'custom-${_custom.length + 1}',
    );
    final body = TextEditingController(text: existing?.body ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'Nueva entrada' : 'Editar entrada'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Título'),
              ),
              TextField(
                controller: id,
                decoration: const InputDecoration(
                  labelText: 'Id (menuentry --id)',
                ),
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
    final entry = CustomEntry(title: title.text, id: id.text, body: body.text);
    final err = CustomEntries.validate(
      entry,
      takenIds: _custom.where((e) => e != existing).map((e) => e.id),
    );
    if (err != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() {
      final i = existing == null ? -1 : _custom.indexOf(existing);
      if (i >= 0) {
        _custom[i] = entry;
      } else {
        _custom.add(entry);
      }
      _syncMenuPaths();
    });
  }

  String _typeLabel(GrubEntryType t) => switch (t) {
    GrubEntryType.kernel => 'Kernel',
    GrubEntryType.otros => 'Otro',
    GrubEntryType.custom => 'Custom',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EZGrubConfig'),
        actions: [
          IconButton(
            tooltip: 'Recargar',
            onPressed: _applying ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _loading || _applying ? null : _apply,
              child: const Text('Aplicar'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [_entriesCard(), _settingsCard(), _customCard()],
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
            Text(
              'Entradas del menú',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text('Toca una entrada para hacerla la predeterminada.'),
            if (_selected == null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'El valor actual de GRUB_DEFAULT ("$_originalDefault") '
                  'no coincide con ninguna entrada conocida. Se conservará '
                  'tal cual hasta que elijas una de la lista.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
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
            Text('Ajustes', style: Theme.of(context).textTheme.titleMedium),
            Row(
              children: [
                const Expanded(child: Text('Tiempo de espera del menú (s):')),
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
                  items: [
                    const DropdownMenuItem(
                      value: 'menu',
                      child: Text('Mostrar menú'),
                    ),
                    const DropdownMenuItem(
                      value: 'hidden',
                      child: Text('Oculto'),
                    ),
                    // p. ej. GRUB_TIMEOUT_STYLE=countdown en el sistema
                    if (_timeoutStyle != 'menu' && _timeoutStyle != 'hidden')
                      DropdownMenuItem(
                        value: _timeoutStyle,
                        child: Text(_timeoutStyle),
                      ),
                  ],
                  onChanged: (v) => setState(() => _timeoutStyle = v ?? 'menu'),
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
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
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
                      onPressed: () => setState(() {
                        _custom.remove(e);
                        _syncMenuPaths();
                      }),
                      icon: const Icon(Icons.delete),
                    ),
                  ],
                ),
              ),
            if (_custom.isEmpty) const Text('Sin entradas custom.'),
          ],
        ),
      ),
    );
  }
}
