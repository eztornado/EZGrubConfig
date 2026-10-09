# EZGrubConfig

Editor gráfico del menú de GRUB para Linux, hecho en Flutter. Elige la entrada por defecto, ajusta el timeout y crea o edita tus propias entradas de arranque sin tocar `grub.cfg` a mano.

UI en español. Desarrollado y probado en CachyOS (Arch-based); debería funcionar en cualquier distro con GRUB2 y `grub-mkconfig`.

## El problema

En distribuciones rolling release como CachyOS, cada actualización regenera `/boot/grub/grub.cfg` y puede cambiar el orden de los kernels del menú de arranque. Además, crear entradas propias exige editar `40_custom` a mano y lanzar `grub-mkconfig`. EZGrubConfig hace ambas cosas desde una GUI.

## Características

- **Entradas del menú** — lista jerárquica de todas las entradas (kernels, otros SO detectados por os-prober y tus entradas custom), incluyendo submenus. Un clic o las flechas ↑↓ eligen la entrada por defecto; la activa queda resaltada.
- **Ajustes** — timeout del menú (`GRUB_TIMEOUT`) y si se muestra u oculta (`GRUB_TIMEOUT_STYLE`).
- **Entradas custom** — alta, edición y borrado de entradas propias en `/etc/grub.d/40_custom`, con validación de sintaxis (bloques `menuentry` con llaves balanceadas) antes de escribir.
- **Aplicar** — escribe los cambios y regenera el `grub.cfg` en un solo paso, mostrando la salida de `grub-mkconfig`.

## Cómo funciona (y por qué es seguro)

- **Sin tocar lo generado.** Las entradas que genera GRUB (kernels, os-prober) son de solo lectura: editarlas sería perder los cambios en la próxima actualización. Las entradas custom viven en `/etc/grub.d/40_custom`, que sí sobrevive a los updates.
- **Default que sobrevive a updates.** La entrada por defecto se fija con `GRUB_DEFAULT` usando el ID estable de la entrada (`submenu-id>entry-id` para entradas anidadas), no su posición en el menú.
- **Edición quirúrgica de `/etc/default/grub`.** Solo se modifican `GRUB_DEFAULT` y `GRUB_TIMEOUT`/`GRUB_TIMEOUT_STYLE`; el resto del archivo se conserva byte a byte.
- **Backups automáticos.** Antes de cada escritura se crea un backup con timestamp (`<archivo>.bak-YYYYMMDD-HHMMSS`). Si `grub-mkconfig` falla, la app ofrece restaurar los backups con un clic.
- **Root solo cuando hace falta.** La app corre como tu usuario y usa `pkexec` (polkit) por acción: leer `grub.cfg`, escribir con backup y aplicar. Cancelar el diálogo de polkit no rompe nada.

## Requisitos

- Linux con GRUB2 y `grub-mkconfig`
- `pkexec` (viene con polkit, presente en prácticamente cualquier distro)
- [Flutter SDK](https://docs.flutter.dev/get-started/install/linux) con soporte de escritorio Linux

## Compilar y ejecutar

```bash
git clone https://github.com/eztornado/EZGrubConfig.git
cd EZGrubConfig
flutter pub get

# Desarrollo
flutter run -d linux

# Release
flutter build linux --release
./build/linux/x64/release/bundle/ezgrubconfig
```

Para instalarlo en el sistema, copia el bundle donde quieras (por ejemplo `/opt/EZGrubConfig`) y ejecuta el binario.

## Tests

Los tests cubren el parser de `grub.cfg`, el redondeo de escritura de `/etc/default/grub` (el resto del archivo queda idéntico byte a byte), el CRUD de entradas custom y la validación de bloques:

```bash
flutter test
```

## Fuera de alcance (a propósito)

- Reordenar físicamente las entradas generadas (GRUB no lo soporta de forma persistente).
- Gestionar los scripts de `/etc/grub.d` (activar/desactivar os-prober, etc.).
- Editar `/boot/grub/grub.cfg` directamente.

## Licencia

Sin definir todavía. Contacta con el autor si quieres usar el código.
