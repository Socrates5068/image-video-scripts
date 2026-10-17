Get-ChildItem -Path . -Include *.mp4, *.mts, *.mkv, *.3gp -Recurse | ForEach-Object {
    if ($_.BaseName -match "_h265$") {
        return # Salta al siguiente archivo sin hacer nada
    }

    $outputName = Join-Path $_.DirectoryName "$($_.BaseName)_h265.mp4"
    
    if (Test-Path $outputName) {
        Write-Host "Saltando $($_.Name) - Ya fue convertido previamente." -ForegroundColor DarkGray
        return
    }

    Write-Host "Procesando video: $($_.DirectoryName)\$($_.Name)" -ForegroundColor Cyan

    ffmpeg -hide_banner -loglevel error -y -i $_.FullName -map_metadata 0 -movflags use_metadata_tags -c:v hevc_nvenc -preset {{preset}} -b:v 2000k -maxrate 2000k -bufsize 4000k -c:a libopus -ac 2 -b:a {{audio_bitrate}} $outputName
    
    if (Test-Path $outputName) {
        (Get-Item $outputName).CreationTime = $_.CreationTime
        (Get-Item $outputName).LastWriteTime = $_.LastWriteTime
    }
}

Write-Host "¡Conversión masiva de videos completada!" -ForegroundColor Green