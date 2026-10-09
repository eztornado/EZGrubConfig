# EZGrubConfig — Diseño

Fecha: 2026-09-20
Plataforma: Linux (desarrollado en CachyOS), Flutter desktop. Solo Linux: la app toca rutas `/etc` y `/boot`.

## Problema

En CachyOS, cada actualización regenera `/boot/grub/grub.cfg` (`grub-mkconfig` desde `/etc/grub.d/10_linux`) y puede cambiar el orden de los kernels del menú de arranque. Además, crear/editar entradas de menú propias exige editar a mano `40_custom` y lanzar `grub-mkconfig`. EZGrubConfig hace ambas cosas desde una GUI.

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Privilegios root | `pkexec` por acción (polkit estándar; la app corre como usuario normal) |
| Edición de entradas | Solo entradas custom en `/etc/grub.d/40_custom`; las generadas (kernels, os-prober) son de solo lectura |
| "Orden de arranque" | Elegir entrada por defecto fijando `GRUB_DEFAULT` (ID estable que sobrevive a updates) + `GRUB_TIMEOUT` |
| Arquitectura | Toda la lógica GRUB en Dart; `pkexec` solo como pasarela de privilegios |

## Arquitectura

App Flutter desktop, UI en español, corre como el usuario. Operaciones root vía `pkexec` con comandos puntuales:

- Leer `grub.cfg`: `pkexec cat /boot/grub/grub.cfg`
- Escribir `/etc/default/grub` y `/etc/grub.d/40_custom`: `pkexec tee <ruta>` (contenido por stdin), con backup `<ruta>.bak-YYYYMMDD-HHMMSS` inmediatamente antes de cada escritura
- Aplicar: `pkexec grub-mkconfig -o /boot/grub/grub.cfg`

Notas de privilegios: `/boot/grub/grub.cfg` es `600 root:root` en CachyOS (requiere pkexec hasta para leer); `/etc/default/grub` y `/etc/grub.d/40_custom` son legibles por todos (lectura directa, escritura con pkexec).

## Componentes (`lib/`)

### `grub_config.dart`
- Modelo: `GrubEntry { title, id, type (kernel|otros|custom), children }` — lista jerárquica (submenu → entradas).
- Parser de `grub.cfg`: reconoce bloques `submenu`/`menuentry` anidados por llaves; extrae `--id`.
- Lector/escritor de `/etc/default/grub`: parsea `CLAVE=valor` (con comillas simples o dobles); al escribir solo modifica `GRUB_DEFAULT` y `GRUB_TIMEOUT`, el resto del archivo se conserva byte a byte.
- La sintaxis de `GRUB_DEFAULT` para una entrada anidada es `submenu-id>entry-id` (los IDs del cfg generado, p. ej. `gnulinux-advanced-UUID>gnulinux-linux-cachyos-advanced-UUID`); para una custom, su `--id` o su título.

### `custom_entries.dart`
- CRUD de entradas en `/etc/grub.d/40_custom`: las entradas son los bloques `menuentry ... }` tras la cabecera `exec tail -n +3 $0` y sus comentarios.
- Extraer lista / añadir / editar / borrar; serializa el archivo completo de vuelta.
- Validación al guardar una entrada: empieza por `menuentry`, llaves balanceadas.

### `pkexec.dart`
- Envoltorio de `Process.run`: `readRoot(path)`, `writeRoot(path, content)` (con backup previo), `runRoot(args)`.
- Detecta cancelación de polkit (exit code distinto de 0 sin stderr de error real) → error tipado "cancelado por el usuario", no excepción cruda.

### `main.dart`
Una pantalla, tres secciones + aplicar:

1. **Entradas** — lista jerárquica de todas las entradas del menú (generadas de solo lectura + custom). Flechas ↑↓ (o clic) eligen la default; la activa según `GRUB_DEFAULT` queda resaltada.
2. **Ajustes** — `GRUB_TIMEOUT` (segundos) y `GRUB_TIMEOUT_STYLE` (mostrar menú / oculto).
3. **Entradas custom** — lista de las de `40_custom` con editor (título + cuerpo de comandos) y alta/baja.
4. **Aplicar** — backup → escribir `/etc/default/grub` y `40_custom` (si cambiaron) → `pkexec grub-mkconfig -o /boot/grub/grub.cfg` → muestra la salida → recarga estado. Cambiar solo default/timeout también exige regenerar porque `GRUB_DEFAULT` queda horneado en la cabecera del cfg.

## Flujo de datos

Arranque: lee `40_custom` y `/etc/default/grub` directo + `pkexec cat grub.cfg` → estado en memoria. Todas las ediciones son en memoria. Aplicar = secuencia pkexec descrita arriba → recarga.

## Errores

- Polkit cancelado → snackbar informativo, sin crash.
- `grub-mkconfig` falla (p. ej. sintaxis rota en una custom) → muestra stderr y ofrece restaurar los `.bak` de esa aplicación (un clic).
- Validación de entrada custom antes de escribir (ver arriba).
- Si falta algún archivo (`40_custom` vacío, `grub.cfg` ausente) → estado vacío con mensaje, no excepción.

## Testing

Un test Dart puro (`test/grub_config_test.dart`) con fixtures de `grub.cfg` y `40_custom` en el repo:
- Parseo jerárquico de submenus/menuentry con `--id`.
- Redondeo de escritura de `/etc/default/grub`: cambia `GRUB_DEFAULT`/`GRUB_TIMEOUT`, el resto idéntico byte a byte.
- CRUD de custom entries: extraer/añadir/editar/borrar conserva la cabecera y las demás entradas.
- Validación de bloques (llaves balanceadas).

La capa pkexec no se testea (es `Process.run`).

## Fuera de alcance

- Reordenar físicamente el menú generado (GRUB no lo soporta; se perdería en cada update).
- Gestionar scripts de `/etc/grub.d` (activar/desactivar os-prober, etc.).
- Modificar `/boot/grub/grub.cfg` a mano.
- Otras plataformas (Windows/macOS).
