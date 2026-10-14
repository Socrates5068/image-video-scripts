# ============================================================
# CONVERSION MASIVA A WEBP CON MAXIMA CONSERVACION DE METADATOS
# ============================================================
# Eliminar el original después de convertir y validar correctamente

$DeleteOriginalAfterSuccess = $true
$ErrorActionPreference = "Continue"

# ------------------------------------------------------------
# CONFIGURACION
# ------------------------------------------------------------

$Quality = 90

# Extensiones de imagen admitidas
$Extensions = @(".jpg", ".jpeg", ".png")

# ------------------------------------------------------------
# COMPROBAR DEPENDENCIAS
# ------------------------------------------------------------

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw "ERROR: FFmpeg no está instalado o no está en el PATH."
}

$FFmpeg = $FFmpegCommand.Source

if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
    throw "ERROR: ExifTool no está instalado o no está en el PATH."
}

# ------------------------------------------------------------
# BUSCAR IMAGENES
# ------------------------------------------------------------

$Files = @(
    Get-ChildItem -LiteralPath . -File -Recurse |
    Where-Object {
        $Extensions -contains $_.Extension.ToLowerInvariant()
    }
)

$Total = $Files.Count
$Converted = 0
$Skipped = 0
$Errors = 0

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host " CONVERSION DE FOTOGRAFIAS A WEBP" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor White
Write-Host "Imagenes encontradas: $Total"
Write-Host "Calidad WebP: $Quality"
Write-Host ""

# ------------------------------------------------------------
# PROCESAR IMAGENES
# ------------------------------------------------------------

foreach ($File in $Files) {

    $OutputName = Join-Path $File.DirectoryName "$($File.BaseName).webp"

    # Evitar sobrescribir archivos existentes
    if (Test-Path -LiteralPath $OutputName) {

        Write-Host "OMITIDO: $($File.FullName)" -ForegroundColor DarkGray
        $Skipped++
        continue
    }

    Write-Host "PROCESANDO: $($File.FullName)" -ForegroundColor Cyan

    # --------------------------------------------------------
    # 1. CONVERTIR A WEBP
    # --------------------------------------------------------
    # -noautorotate: evita que FFmpeg aplique automáticamente
    # la orientación EXIF a los píxeles.
    #
    # -map_metadata -1: evita copiar metadatos automáticamente
    # desde FFmpeg. Los copiaremos después con ExifTool.
    #
    # -frames:v 1: genera una sola imagen.
    #
    # El original nunca se modifica.

    & ffmpeg `
        -hide_banner `
        -loglevel error `
        -nostdin `
        -noautorotate `
        -i $File.FullName `
        -map 0:v:0 `
        -frames:v 1 `
        -map_metadata -1 `
        -c:v libwebp `
        -pix_fmt yuv420p `
        -color_range pc `
        -q:v $Quality `
        $OutputName

    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $OutputName)) {

        Write-Host "ERROR: Fallo la conversion de $($File.Name)" -ForegroundColor Red

        if (Test-Path -LiteralPath $OutputName) {
            Remove-Item -LiteralPath $OutputName -Force
        }

        $Errors++
        continue
    }

    # --------------------------------------------------------
    # 2. COPIAR METADATOS CON EXIFTOOL
    # --------------------------------------------------------
    # Se intenta conservar:
    # - EXIF: fecha de captura, GPS, cámara, lente, exposición, etc.
    # - XMP: metadatos adicionales compatibles.
    # - IPTC: descripción, autor, palabras clave, etc.
    # - ICC_Profile: perfil de color.
    #
    # No se utiliza Orientation# porque se quiere conservar
    # el valor original de orientación, si es compatible.
    #
    # Algunas etiquetas no se pueden representar en WebP.

    & exiftool `
        -TagsFromFile $File.FullName `
        "-EXIF:All" `
        "-XMP:All" `
        "-IPTC:All" `
        "-ICC_Profile" `
        -overwrite_original `
        -P `
        -quiet `
        $OutputName

    if ($LASTEXITCODE -ne 0) {

        Write-Host "ERROR: No se pudieron copiar todos los metadatos de $($File.Name)" `
            -ForegroundColor Red

        $Errors++
        continue
    }

    # --------------------------------------------------------
    # 3. RESTAURAR FECHAS DEL SISTEMA DE ARCHIVOS
    # --------------------------------------------------------

    try {

        $OutputFile = Get-Item -LiteralPath $OutputName

        $OutputFile.CreationTime = $File.CreationTime
        $OutputFile.LastWriteTime = $File.LastWriteTime
        $OutputFile.LastAccessTime = $File.LastAccessTime

    }
    catch {

        Write-Host "ADVERTENCIA: No se pudieron restaurar todas las fechas de $($File.Name)" `
            -ForegroundColor Yellow
    }

    # --------------------------------------------------------
    # 4. VERIFICAR FECHA DE CAPTURA Y GPS
    # --------------------------------------------------------

    $Metadata = & exiftool `
        -json `
        -DateTimeOriginal `
        -CreateDate `
        -GPSLatitude `
        -GPSLongitude `
        -Make `
        -Model `
        $OutputName 2>$null

    if ($LASTEXITCODE -eq 0 -and $Metadata) {

        try {

            $Info = ($Metadata | ConvertFrom-Json)[0]

            $CaptureDate = $Info.DateTimeOriginal
            $PhoneModel = $Info.Model

            if ($CaptureDate) {
                Write-Host "  Fecha de captura: $CaptureDate" -ForegroundColor Gray
            }
            else {
                Write-Host "  ADVERTENCIA: No se encontro DateTimeOriginal." `
                    -ForegroundColor Yellow
            }

            if ($Info.GPSLatitude -and $Info.GPSLongitude) {
                Write-Host "  GPS: Conservado" -ForegroundColor Gray
            }

            if ($PhoneModel) {
                Write-Host "  Dispositivo: $PhoneModel" -ForegroundColor Gray
            }
        }
        catch {

            Write-Host "  ADVERTENCIA: No se pudieron interpretar los metadatos." `
                -ForegroundColor Yellow
        }
    }

    # --------------------------------------------------------
    # 5. VALIDAR EL WEBP ANTES DE ELIMINAR EL ORIGINAL
    # --------------------------------------------------------

    if ($DeleteOriginalAfterSuccess) {

        # Confirmar que el archivo existe y no está vacío.
        if (-not (Test-Path -LiteralPath $OutputName -PathType Leaf)) {
            Write-Host "ERROR: No existe el WebP. Se conserva el original." -ForegroundColor Red
            $Errors++
            continue
        }

        $OutputFile = Get-Item -LiteralPath $OutputName

        if ($OutputFile.Length -le 0) {
            Write-Host "ERROR: El WebP está vacío. Se conserva el original." -ForegroundColor Red
            Remove-Item -LiteralPath $OutputName -Force -ErrorAction SilentlyContinue
            $Errors++
            continue
        }

        # Comprobar que FFmpeg pueda decodificar la imagen.
        & $FFmpeg `
            -hide_banner `
            -loglevel error `
            -nostdin `
            -i $OutputName `
            -frames:v 1 `
            -f null NUL

        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: El WebP no superó la validación. Se conserva el original." -ForegroundColor Red

            Remove-Item -LiteralPath $OutputName -Force -ErrorAction SilentlyContinue

            $Errors++
            continue
        }

        # Eliminar únicamente el original que corresponde a esta conversión.
        try {
            Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
            Write-Host "Original eliminado: $($File.Name)" -ForegroundColor Yellow
        }
        catch {
            Write-Host "ADVERTENCIA: No se pudo eliminar el original: $($File.Name)" -ForegroundColor Yellow
            Write-Host $_.Exception.Message -ForegroundColor DarkYellow
        }
    }

    Write-Host "OK: $($File.Name)" -ForegroundColor Green

    $Converted++
}

# ------------------------------------------------------------
# RESUMEN FINAL
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host " PROCESO FINALIZADO" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor White

Write-Host "Total de imagenes:       $Total"
Write-Host "Convertidas:             $Converted"
Write-Host "Omitidas:                $Skipped"
Write-Host "Errores/advertencias:    $Errors"

Write-Host ""
Write-Host "Conversion terminada." -ForegroundColor Green
