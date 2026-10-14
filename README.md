# Image and Video Scripts

Scripts de PowerShell para convertir imágenes a WebP y videos a H.265/HEVC con audio Opus. Ambos recorren recursivamente la **carpeta actual** y guardan las conversiones junto a cada archivo de origen.

> **Importante:** los dos scripts eliminan el archivo original después de completar y validar la conversión. Haz una copia de seguridad y prueba primero con copias de tus archivos. Para conservar los originales, cambia `$DeleteOriginalAfterSuccess` a `$false` en el script correspondiente antes de ejecutarlo.

## Requisitos

- Windows con PowerShell 5.1 o PowerShell 7.
- [FFmpeg](https://ffmpeg.org/) y FFprobe disponibles en `PATH`.
- [ExifTool](https://exiftool.org/) disponible en `PATH`.
- Para convertir videos, FFmpeg debe incluir el codificador `hevc_nvenc` y se necesita una GPU NVIDIA compatible con NVENC.
- Para la salida de video, FFmpeg debe incluir también el codificador de audio `libopus`.

Los scripts detienen la ejecución si no encuentran alguna de sus dependencias necesarias. El conversor de video comprueba además que `hevc_nvenc` esté disponible.

## Uso

Ejecuta el script desde la carpeta que contiene los archivos que quieres procesar (puede ser una carpeta de trabajo independiente). La búsqueda incluye sus subcarpetas. Por ejemplo:

```powershell
Set-Location "D:\Media\Fotos"
```

Para videos:

```powershell
Set-Location "D:\Media\Videos"
```

Si la política de ejecución de PowerShell impide ejecutar el script, puedes invocarlo para esta sesión sin cambiar la configuración permanente:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Después, vuelve a ejecutar el comando del script. Ajusta las rutas de los ejemplos a tu equipo.

## Conversor de imágenes

Script: [`image/convert_to_webp.ps1`](image/convert_to_webp.ps1)

- Formatos de entrada: `.jpg`, `.jpeg` y `.png`.
- Salida: un archivo `.webp` en la misma carpeta, con calidad configurada en `90`.
- Omite la imagen si ya existe un WebP con el mismo nombre base; no sobrescribe archivos.
- Intenta copiar metadatos EXIF, XMP, IPTC y el perfil ICC con ExifTool. La compatibilidad de etiquetas depende del formato WebP.
- Conserva las fechas de creación, modificación y acceso del archivo en el sistema de archivos.
- Comprueba que el WebP exista, no esté vacío y pueda decodificarse antes de eliminar el original.

La orientación EXIF se conserva como metadato cuando es compatible; FFmpeg no rota los píxeles automáticamente durante la conversión.
Si falla la copia de metadatos, puede quedar un WebP generado junto al original. Como los archivos de salida existentes se omiten, revisa ese WebP antes de volver a ejecutar el script.

## Conversor de video

Script: [`video/convert_to_H265.ps1`](video/convert_to_H265.ps1)

- Formatos de entrada: `.mp4`, `.mts`, `.mkv` y `.3gp`.
- Salida: `nombre_h265.mp4` junto al video original. Omite nombres que ya terminen en `_h265` y salidas que ya existan.
- Codifica video con NVENC HEVC (`hevc_nvenc`, preset `p5`) y audio con Opus, estéreo, a 128 kb/s y 48 kHz.
- Usa tasas de bits distintas según la frecuencia de cuadros: menos de 45 FPS, 5.000 kb/s (máximo 7.000 kb/s); 45 FPS o más, 10.000 kb/s (máximo 12.000 kb/s).
- Desentrelaza fuentes que FFprobe identifica como entrelazadas.
- Intenta conservar capítulos y metadatos compatibles. También intenta recuperar la fecha de grabación de ciertos metadatos Sony o QuickTime y la escribe en la salida cuando está disponible.
- Valida que la salida contenga video HEVC, audio Opus y duración válida; antes de borrar el origen, también intenta decodificar el archivo completo.

La salida MP4 necesita al menos una pista de audio para superar la validación de este script. Si no se puede identificar la fecha de grabación o copiar alguna etiqueta, el script informa una advertencia; algunas etiquetas no son compatibles con MP4.

## Configuración

Los valores se ajustan editando las variables al principio del script correspondiente. En particular:

- `$DeleteOriginalAfterSuccess`: establece `$false` para conservar los originales.
- En imágenes, `$Quality` controla la calidad WebP y `$Extensions` los formatos examinados.
- En videos, `$Extensions`, `$Preset`, las tasas de bits y `$HighFPSThreshold` controlan qué archivos procesa y los parámetros de codificación.

No se sobrescriben las salidas existentes. Si la conversión falla, revisa el resumen de errores y advertencias que imprime el script y conserva el original para investigar.
