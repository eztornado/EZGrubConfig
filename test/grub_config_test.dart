import 'dart:io';

import 'package:ezgrubconfig/custom_entries.dart';
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

  final defaultGrubRaw = File('test/fixtures/default_grub').readAsStringSync();

  test('DefaultGrub.valueOf no confunde claves con prefijo común', () {
    final dg = DefaultGrub(defaultGrubRaw);
    expect(
      dg.valueOf('GRUB_TIMEOUT'),
      '5',
    ); // NO 'menu' (STYLE comparte prefijo)
    expect(dg.valueOf('GRUB_TIMEOUT_STYLE'), 'menu');
    expect(
      dg.valueOf('GRUB_DEFAULT'),
      'gnulinux-advanced-uuid1>'
      'gnulinux-linux-cachyos-lts-advanced-uuid1',
    );
    expect(dg.valueOf('GRUB_INEXISTENTE'), isNull);
  });

  test('withValues cambia solo las claves pedidas', () {
    final result = DefaultGrub(defaultGrubRaw)
        .withValues({'GRUB_DEFAULT': 'nuevo-id', 'GRUB_TIMEOUT': '3'});
    final dg = DefaultGrub(result);
    expect(dg.valueOf('GRUB_DEFAULT'), 'nuevo-id');
    expect(dg.valueOf('GRUB_TIMEOUT'), '3');
    expect(dg.valueOf('GRUB_TIMEOUT_STYLE'), 'menu');
    expect(
      dg.valueOf('GRUB_CMDLINE_LINUX_DEFAULT'),
      'quiet splash clocksource=tsc tsc=reliable',
    );
    // líneas no tocadas, byte a byte
    String? lineOf(String s, String key) => s
        .split('\n')
        .firstWhere((l) => l.startsWith('$key='), orElse: () => '');
    expect(
      lineOf(result, 'GRUB_CMDLINE_LINUX_DEFAULT'),
      lineOf(defaultGrubRaw, 'GRUB_CMDLINE_LINUX_DEFAULT'),
    );
    expect(
      lineOf(result, 'GRUB_CMDLINE_LINUX'),
      lineOf(defaultGrubRaw, 'GRUB_CMDLINE_LINUX'),
    );
  });

  test('withValues respeta las comillas dobles existentes', () {
    final result = DefaultGrub(defaultGrubRaw)
        .withValues({'GRUB_CMDLINE_LINUX_DEFAULT': 'quiet'});
    expect(result, contains('GRUB_CMDLINE_LINUX_DEFAULT="quiet"'));
    expect(DefaultGrub(result).valueOf('GRUB_CMDLINE_LINUX_DEFAULT'), 'quiet');
  });

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
      CustomEntry(title: 'Nuevo', id: 'nuevo-1', body: 'linux /vmlinuz'),
    );
    final re = CustomEntries.parse(ce.serialize());
    expect(re.entries, hasLength(2));
    expect(re.header, ce.header);
    expect(re.entries[1].title, 'Nuevo');

    re.entries[0].body = 'linux /boot/vmlinuz-rescue2';
    expect(
      CustomEntries.parse(re.serialize()).entries[0].body,
      contains('vmlinuz-rescue2'),
    );

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
        CustomEntry(title: ' ', id: 'x', body: 'linux /vmlinuz'),
      ),
      isNotNull,
    );
    expect(
      CustomEntries.validate(
        CustomEntry(title: 'T', id: 'x', body: 'search {x'),
      ),
      isNotNull,
    );
    expect(
      CustomEntries.validate(
        CustomEntry(title: 'T', id: 'x', body: 'echo \${var}'),
      ),
      isNull,
    ); // ${var} balancea a 0
    expect(
      CustomEntries.validate(
        CustomEntry(title: 'T', id: 'x', body: 'linux /vmlinuz'),
      ),
      isNull,
    );
  });

  test(
    'validate rechaza comilla simple en el título (GRUB no tiene escape)',
    () {
      expect(
        CustomEntries.validate(
          CustomEntry(title: "Res'cue", id: 'x', body: 'linux /vmlinuz'),
        ),
        isNotNull,
      );
    },
  );

  test('validate rechaza comilla simple, > y saltos de línea en el id', () {
    expect(
      CustomEntries.validate(
        CustomEntry(title: 'T', id: "i'd", body: 'linux /vmlinuz'),
      ),
      isNotNull,
    );
    expect(
      CustomEntries.validate(
        CustomEntry(title: 'T', id: 'i>d', body: 'linux /vmlinuz'),
      ),
      isNotNull,
    );
    expect(
      CustomEntries.validate(
        CustomEntry(title: 'T', id: 'i\nd', body: 'linux /vmlinuz'),
      ),
      isNotNull,
    );
    expect(
      CustomEntries.validate(
        CustomEntry(title: 'T', id: 'i\rd', body: 'linux /vmlinuz'),
      ),
      isNotNull,
    );
  });

  test('validate rechaza ids duplicados via takenIds', () {
    final e = CustomEntry(title: 'T', id: 'usado', body: 'linux /vmlinuz');
    expect(CustomEntries.validate(e, takenIds: ['otro', 'usado']), isNotNull);
    expect(CustomEntries.validate(e, takenIds: ['otro']), isNull);
  });

  test('serialize no escapa el título (GRUB no tiene escapes)', () {
    final ce = CustomEntries('', [
      CustomEntry(title: "Sin'escape", id: 'x', body: 'linux /vmlinuz'),
    ]);
    final out = ce.serialize();
    expect(out, contains("menuentry 'Sin'escape' --id 'x' {"));
    expect(out, isNot(contains(r'\')));
  });

  group('resolveGrubDefault', () {
    // Fixture: [submenu gnulinux-advanced-uuid1 (2 kernels), hoja Windows]
    final entries = parseGrubCfg(cfg);

    test(
      "índice numérico cuenta entradas de NIVEL SUPERIOR ('1' → Windows)",
      () {
        // GRUB_DEFAULT=1 es la segunda entrada de nivel superior (Windows),
        // NO el segundo kernel del submenu.
        expect(resolveGrubDefault('1', entries), 'osprober-chain-uuid2');
      },
    );

    test("'0' resuelve el submenu a su primer hoja", () {
      expect(
        resolveGrubDefault('0', entries),
        'gnulinux-advanced-uuid1>gnulinux-linux-cachyos-advanced-uuid1',
      );
    });

    test('índices fuera de rango (y negativos) → null', () {
      expect(resolveGrubDefault('3', entries), isNull);
      expect(resolveGrubDefault('-1', entries), isNull);
    });

    test('ruta completa de hoja coincide, id desconocido → null', () {
      expect(
        resolveGrubDefault(
          'gnulinux-advanced-uuid1>gnulinux-linux-cachyos-lts-advanced-uuid1',
          entries,
        ),
        'gnulinux-advanced-uuid1>gnulinux-linux-cachyos-lts-advanced-uuid1',
      );
      expect(resolveGrubDefault('inexistente', entries), isNull);
    });

    test('id de submenu a secas resuelve a su primer hoja', () {
      expect(
        resolveGrubDefault('gnulinux-advanced-uuid1', entries),
        'gnulinux-advanced-uuid1>gnulinux-linux-cachyos-advanced-uuid1',
      );
    });

    test('primer descendiente hoja es recursivo en submenus anidados', () {
      final nested = [
        GrubEntry(
          title: 'Sub A',
          id: 'a',
          type: GrubEntryType.otros,
          children: [
            GrubEntry(
              title: 'Sub B',
              id: 'b',
              type: GrubEntryType.otros,
              children: [
                GrubEntry(
                  title: 'Hoja b1',
                  id: 'b1',
                  type: GrubEntryType.kernel,
                ),
                GrubEntry(
                  title: 'Hoja b2',
                  id: 'b2',
                  type: GrubEntryType.kernel,
                ),
              ],
            ),
            GrubEntry(title: 'Hoja a1', id: 'a1', type: GrubEntryType.kernel),
          ],
        ),
        GrubEntry(title: 'Hoja Z', id: 'z', type: GrubEntryType.otros),
      ];
      expect(resolveGrubDefault('0', nested), 'a>b>b1');
      expect(resolveGrubDefault('a', nested), 'a>b>b1');
      expect(resolveGrubDefault('1', nested), 'z');
      // en este modelo submenu == children.isNotEmpty, así que "submenu sin
      // hojas" no existe: una entrada sin hijos es hoja y resuelve a su id
      final vacio = [
        GrubEntry(title: 'Vacío', id: 'v', type: GrubEntryType.otros),
      ];
      expect(resolveGrubDefault('0', vacio), 'v');
    });
  });
}
