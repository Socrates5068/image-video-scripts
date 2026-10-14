# ============================================================
# CONVERSION DE VIDEOS A H.265/HEVC + OPUS
# Conservacion de metadatos con FFmpeg y ExifTool
# ============================================================
# Eliminar el original después de convertir y validar correctamente

$DeleteOriginalAfterSuccess = $true
$ErrorActionPreference = "Stop"

# ---------------- CONFIGURACION ----------------

$Extensions = @(".mp4", ".mts", ".mkv", ".3gp")

$Preset = "p5"

# Videos de frecuencia de fotogramas normal
$BitrateNormal = "5000k"
$MaxrateNormal = "7000k"
$BufsizeNormal = "14000k"

# Videos de alta frecuencia de fotogramas
$BitrateHighFPS = "10000k"
$MaxrateHighFPS = "12000k"
$BufsizeHighFPS = "24000k"

$HighFPSThreshold = 45

# Audio
$AudioBitrate = "128k"
$AudioSampleRate = "48000"

# Desentrelazar videos entrelazados
$DeinterlaceFilter = "bwdif=mode=send_field:parity=auto:deint=interlaced"

# ---------------- VERIFICAR HERRAMIENTAS ----------------

$FFmpeg = Get-Command "ffmpeg.exe" -ErrorAction SilentlyContinue
if (-not $FFmpeg) {
    $FFmpeg = Get-Command "ffmpeg" -ErrorAction SilentlyContinue
}

$FFprobe = Get-Command "ffprobe.exe" -ErrorAction SilentlyContinue
if (-not $FFprobe) {
    $FFprobe = Get-Command "ffprobe" -ErrorAction SilentlyContinue
}

$ExifTool = Get-Command "exiftool.exe" -ErrorAction SilentlyContinue
if (-not $ExifTool) {
    $ExifTool = Get-Command "exiftool" -ErrorAction SilentlyContinue
}

if (-not $FFmpeg -or -not $FFprobe) {
    throw "No se encontro FFmpeg o FFprobe."
}

if (-not $ExifTool) {
    throw "No se encontro ExifTool. Es necesario para gestionar los metadatos."
}

$EncoderList = & $FFmpeg.Source -hide_banner -encoders 2>&1 |
Out-String

if ($EncoderList -notmatch "hevc_nvenc") {
    throw "FFmpeg no tiene disponible el codificador hevc_nvenc."
}

# ---------------- FUNCIONES ----------------

function Get-ExifValue {
    param(
        [string]$Path,
        [string]$Tag
    )

    $Result = & $ExifTool.Source -s3 "-$Tag" $Path 2>$null

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $Value = ($Result | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return $Value
}

function Get-VideoInfo {
    param([string]$Path)

    $Result = & $FFprobe.Source `
        -v error `
        -select_streams v:0 `
        -show_entries "stream=width,height,avg_frame_rate,r_frame_rate,field_order,codec_name" `
        -of json `
        $Path 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "FFprobe no pudo analizar el video."
    }

    $Info = ($Result -join "`n") | ConvertFrom-Json

    if (-not $Info.streams -or $Info.streams.Count -eq 0) {
        throw "No se encontro una pista de video."
    }

    return $Info.streams[0]
}

function ConvertTo-FPS {
    param([string]$Rate)

    if ([string]::IsNullOrWhiteSpace($Rate) -or $Rate -eq "0/0") {
        return 0.0
    }

    $Parts = $Rate -split "/"

    if ($Parts.Count -eq 2) {
        $Numerator = [double]$Parts[0]
        $Denominator = [double]$Parts[1]

        if ($Denominator -eq 0) {
            return 0.0
        }

        return $Numerator / $Denominator
    }

    return [double]$Rate
}

function Test-ValidOutput {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    if ((Get-Item -LiteralPath $Path).Length -le 0) {
        return $false
    }

    $Result = & $FFprobe.Source `
        -v error `
        -show_entries "format=duration:stream=codec_type,codec_name" `
        -of json `
        $Path 2>&1

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    try {
        $Info = ($Result -join "`n") | ConvertFrom-Json

        $Video = @(
            $Info.streams |
            Where-Object {
                $_.codec_type -eq "video" -and
                $_.codec_name -eq "hevc"
            }
        )

        $Audio = @(
            $Info.streams |
            Where-Object {
                $_.codec_type -eq "audio" -and
                $_.codec_name -eq "opus"
            }
        )

        if ($Video.Count -eq 0 -or $Audio.Count -eq 0) {
            return $false
        }

        if ([double]$Info.format.duration -le 0) {
            return $false
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-RecordingDateUTC {
    param([string]$SourcePath)

    # Algunas camaras Sony guardan la fecha en la estructura H264.
    $SonyDate = Get-ExifValue -Path $SourcePath -Tag "H264:DateTimeOriginal"

    if ($SonyDate) {
        # Ejemplo: 2021:05:13 11:53:30-04:00
        if ($SonyDate -match '(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})([+-]\d{2}:\d{2})$') {
            $DatePart = $Matches[1]
            $OffsetPart = $Matches[2]

            $ParsedDate = [DateTimeOffset]::ParseExact(
                "$DatePart$OffsetPart",
                "yyyy:MM:dd HH:mm:sszzz",
                [Globalization.CultureInfo]::InvariantCulture
            )

            return $ParsedDate.UtcDateTime.ToString(
                "yyyy:MM:dd HH:mm:ss",
                [Globalization.CultureInfo]::InvariantCulture
            )
        }

        # Fecha sin zona horaria: no inventar una conversion UTC.
        return $null
    }

    # Para MP4 de Android, usar la fecha QuickTime original.
    $QuickTimeDate = Get-ExifValue -Path $SourcePath -Tag "QuickTime:CreateDate"

    if ($QuickTimeDate -match '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$') {
        return $QuickTimeDate
    }

    return $null
}

# ---------------- BUSCAR VIDEOS ----------------

$Files = @(
    Get-ChildItem -LiteralPath "." -Recurse -File |
    Where-Object {
        $Extensions -contains $_.Extension.ToLowerInvariant()
    }
)

if ($Files.Count -eq 0) {
    Write-Host "No se encontraron videos compatibles." -ForegroundColor Yellow
    return
}

$Total = $Files.Count
$Converted = 0
$Skipped = 0
$Errors = 0
$Warnings = 0

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " CONVERSION H.265 + OPUS"
Write-Host " Videos encontrados: $Total"
Write-Host " Audio: Opus estereo, 128 kbps, 48 kHz"
Write-Host "============================================================" -ForegroundColor Cyan

# ---------------- PROCESAMIENTO ----------------

for ($Index = 0; $Index -lt $Files.Count; $Index++) {

    $File = $Files[$Index]

    if ($File.BaseName -match "_h265$") {
        $Skipped++
        Write-Host "OMITIDO: $($File.Name)" -ForegroundColor DarkGray
        continue
    }

    $OutputName = Join-Path `
        $File.DirectoryName `
        "$($File.BaseName)_h265.mp4"

    if (Test-Path -LiteralPath $OutputName) {
        $Skipped++
        Write-Host "YA EXISTE: $OutputName" -ForegroundColor DarkGray
        continue
    }

    Write-Host ""
    Write-Host "[$($Index + 1)/$Total] $($File.FullName)" -ForegroundColor Cyan

    # Guardar fechas del archivo de Windows
    $OriginalCreationTime = $File.CreationTime
    $OriginalLastWriteTime = $File.LastWriteTime
    $OriginalLastAccessTime = $File.LastAccessTime

    $OutputCreated = $false

    try {
        $VideoInfo = Get-VideoInfo -Path $File.FullName

        $FPS = ConvertTo-FPS -Rate $VideoInfo.avg_frame_rate

        if ($FPS -le 0) {
            $FPS = ConvertTo-FPS -Rate $VideoInfo.r_frame_rate
        }

        Write-Host "Resolucion: $($VideoInfo.width)x$($VideoInfo.height)"
        Write-Host ("FPS de entrada: {0:N3}" -f $FPS)
        Write-Host "Orden de campos: $($VideoInfo.field_order)"

        if ($FPS -ge $HighFPSThreshold) {
            $VideoBitrate = $BitrateHighFPS
            $VideoMaxrate = $MaxrateHighFPS
            $VideoBufsize = $BufsizeHighFPS
        }
        else {
            $VideoBitrate = $BitrateNormal
            $VideoMaxrate = $MaxrateNormal
            $VideoBufsize = $BufsizeNormal
        }

        # Detectar la fecha de grabacion antes de convertir.
        $RecordingDateUTC = Get-RecordingDateUTC -SourcePath $File.FullName

        if ($RecordingDateUTC) {
            Write-Host "Fecha de grabacion UTC: $RecordingDateUTC"
        }
        else {
            Write-Host "No se pudo identificar una fecha de grabacion compatible." `
                -ForegroundColor Yellow
        }

        # Crear un archivo temporal para no confundir una salida
        # incompleta con una conversion terminada.
        $TempOutput = Join-Path `
            $File.DirectoryName `
            "$($File.BaseName)_h265_TEMP.mp4"

        if (Test-Path -LiteralPath $TempOutput) {
            Remove-Item -LiteralPath $TempOutput -Force
        }

        # Argumentos base de FFmpeg
        $FFmpegArgs = @(
            "-hide_banner",
            "-loglevel", "warning",
            "-y",
            "-i", $File.FullName,

            "-map", "0:v:0",
            "-map", "0:a?",

            "-map_metadata", "0",
            "-map_chapters", "0",

            "-c:v", "hevc_nvenc",
            "-preset", $Preset,
            "-b:v", $VideoBitrate,
            "-maxrate", $VideoMaxrate,
            "-bufsize", $VideoBufsize,
            "-tag:v", "hvc1",

            "-c:a", "libopus",
            "-b:a", $AudioBitrate,
            "-ac", "2",
            "-ar", $AudioSampleRate,

            "-movflags", "+use_metadata_tags"
        )

        # HEVC no conserva el entrelazado como AVC entrelazado.
        # Desentrelazar cuando FFprobe identifica una fuente entrelazada.
        if (
            $VideoInfo.field_order -and
            $VideoInfo.field_order -notin @("progressive", "unknown", "")
        ) {
            Write-Host "Aplicando desentrelazado para mejorar el movimiento..." `
                -ForegroundColor Yellow

            $FFmpegArgs += @("-vf", $DeinterlaceFilter)
        }

        # Asignar la fecha al contenedor MP4 cuando se conoce.
        if ($RecordingDateUTC) {
            $CreationTimeISO = (
                [DateTime]::ParseExact(
                    $RecordingDateUTC,
                    "yyyy:MM:dd HH:mm:ss",
                    [Globalization.CultureInfo]::InvariantCulture
                ).ToString("yyyy-MM-ddTHH:mm:ssZ")
            )

            $FFmpegArgs += @("-metadata", "creation_time=$CreationTimeISO")
            $FFmpegArgs += @("-metadata:s:v:0", "creation_time=$CreationTimeISO")
            $FFmpegArgs += @("-metadata:s:a:0", "creation_time=$CreationTimeISO")
        }

        $FFmpegArgs += @($TempOutput)

        & $FFmpeg.Source @FFmpegArgs

        if ($LASTEXITCODE -ne 0) {
            throw "FFmpeg fallo con codigo $LASTEXITCODE."
        }

        if (-not (Test-ValidOutput -Path $TempOutput)) {
            throw "El archivo temporal no paso la validacion."
        }

        # Copiar metadatos compatibles de Android, Sony y otros archivos.
        # No todas las etiquetas propietarias pueden escribirse en MP4.
        Write-Host "Aplicando metadatos compatibles..." -ForegroundColor Yellow

        $ExifArgs = @(
            "-TagsFromFile", $File.FullName,
            "-GPS:all",
            "-Keys:all",
            "-UserData:all",
            "-ItemList:all",
            "-overwrite_original",
            $TempOutput
        )

        & $ExifTool.Source @ExifArgs

        if ($LASTEXITCODE -ne 0) {
            $Warnings++
            Write-Warning "ExifTool no pudo copiar todos los metadatos."
        }

        # Escribir fechas globales, fabricante y modelo en etiquetas MP4.
        $Make = Get-ExifValue -Path $File.FullName -Tag "H264:Make"
        $Model = Get-ExifValue -Path $File.FullName -Tag "H264:Model"

        if (-not $Make) {
            $Make = Get-ExifValue -Path $File.FullName -Tag "QuickTime:Make"
        }

        if (-not $Model) {
            $Model = Get-ExifValue -Path $File.FullName -Tag "QuickTime:Model"
        }

        $MetadataArgs = @("-overwrite_original")

        if ($RecordingDateUTC) {
            $MetadataArgs += @(
                "-QuickTime:CreateDate=$RecordingDateUTC",
                "-QuickTime:ModifyDate=$RecordingDateUTC",
                "-Keys:CreationTime=${RecordingDateUTC}Z"
            )
        }

        if ($Make) {
            $MetadataArgs += "-Keys:Make=$Make"
        }

        if ($Model) {
            $MetadataArgs += "-Keys:Model=$Model"
        }

        $MetadataArgs += $TempOutput

        & $ExifTool.Source @MetadataArgs

        if ($LASTEXITCODE -ne 0) {
            $Warnings++
            Write-Warning "No se pudieron escribir todos los metadatos adicionales."
        }

        # Validar nuevamente después de modificar metadatos.
        if (-not (Test-ValidOutput -Path $TempOutput)) {
            throw "La salida temporal no paso la validacion final."
        }

        # Renombrar únicamente cuando la conversión haya terminado.
        Move-Item -LiteralPath $TempOutput -Destination $OutputName

        $OutputCreated = $true

        # Restaurar fechas de Windows.
        $OutputFile = Get-Item -LiteralPath $OutputName

        $OutputFile.CreationTime = $OriginalCreationTime
        $OutputFile.LastWriteTime = $OriginalLastWriteTime
        $OutputFile.LastAccessTime = $OriginalLastAccessTime

        $OriginalSizeMB = [math]::Round($File.Length / 1MB, 2)
        $OutputSizeMB = [math]::Round(
            (Get-Item -LiteralPath $OutputName).Length / 1MB,
            2
        )

        $Converted++

        Write-Host "CONVERSION COMPLETADA" -ForegroundColor Green
        Write-Host "Original: $OriginalSizeMB MB"
        Write-Host "Salida:   $OutputSizeMB MB"

        # ====================================================
        # VALIDAR Y ELIMINAR ORIGINAL
        # ====================================================

        if ($DeleteOriginalAfterSuccess) {

            Write-Host "Validando el archivo antes de eliminar el original..."

            if (-not (Test-ValidOutput -Path $OutputName)) {
                throw "La validación final falló. Se conservará el original."
            }

            # Comprobar que el video completo pueda decodificarse.
            & $FFmpeg.Source `
                -hide_banner `
                -loglevel error `
                -xerror `
                -i $OutputName `
                -map "0:v:0" `
                -map "0:a?" `
                -f null NUL

            if ($LASTEXITCODE -ne 0) {
                throw "Falló la decodificación completa. Se conservará el original."
            }

            # Eliminar exactamente el original de esta iteración.
            Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop

            Write-Host "Original eliminado: $($File.Name)" -ForegroundColor Yellow
        }
        else {
            Write-Host "Original conservado: $($File.Name)" -ForegroundColor Cyan
        }
    }
    catch {
        $Errors++

        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red

        $TempOutput = Join-Path `
            $File.DirectoryName `
            "$($File.BaseName)_h265_TEMP.mp4"

        if (Test-Path -LiteralPath $TempOutput) {
            Remove-Item -LiteralPath $TempOutput -Force `
                -ErrorAction SilentlyContinue
        }

        # Si se produjo una salida definitiva pero inválida, eliminarla.
        if (
            (Test-Path -LiteralPath $OutputName) -and
            -not (Test-ValidOutput -Path $OutputName)
        ) {
            Remove-Item -LiteralPath $OutputName -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

# ---------------- RESUMEN ----------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PROCESO FINALIZADO" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Encontrados  : $Total"
Write-Host "Convertidos  : $Converted" -ForegroundColor Green
Write-Host "Omitidos     : $Skipped" -ForegroundColor DarkGray
Write-Host "Errores      : $Errors" -ForegroundColor Red
Write-Host "Advertencias : $Warnings" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
