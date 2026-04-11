[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$SourceSvg = "",
    [string]$OutputDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-EffectiveRepoRoot {
    param([string]$RequestedRepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRepoRoot)) {
        return (Resolve-Path -LiteralPath $RequestedRepoRoot).Path
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-EmbeddedPngBytes {
    param([Parameter(Mandatory = $true)][string]$SvgPath)

    $svgContent = [System.IO.File]::ReadAllText($SvgPath)
    $match = [System.Text.RegularExpressions.Regex]::Match(
        $svgContent,
        'href="data:image/png;base64,([^"]+)"',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        throw "The SVG does not contain an embedded PNG data URL: $SvgPath"
    }

    return [System.Convert]::FromBase64String($match.Groups[1].Value)
}

function New-ResizedPngBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$SourceBytes,
        [int]$Size = 256
    )

    Add-Type -AssemblyName System.Drawing

    $inputStream = New-Object System.IO.MemoryStream(,$SourceBytes)
    try {
        $sourceImage = [System.Drawing.Image]::FromStream($inputStream)
        try {
            $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.Clear([System.Drawing.Color]::Transparent)
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.DrawImage($sourceImage, 0, 0, $Size, $Size)
                } finally {
                    $graphics.Dispose()
                }

                $outputStream = New-Object System.IO.MemoryStream
                try {
                    $bitmap.Save($outputStream, [System.Drawing.Imaging.ImageFormat]::Png)
                    return $outputStream.ToArray()
                } finally {
                    $outputStream.Dispose()
                }
            } finally {
                $bitmap.Dispose()
            }
        } finally {
            $sourceImage.Dispose()
        }
    } finally {
        $inputStream.Dispose()
    }
}

function Write-IcoFromPng {
    param(
        [Parameter(Mandatory = $true)][byte[]]$PngBytes,
        [Parameter(Mandatory = $true)][string]$IcoPath
    )

    $fileStream = [System.IO.File]::Open($IcoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $writer = New-Object System.IO.BinaryWriter($fileStream)
        try {
            $writer.Write([UInt16]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]1)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$PngBytes.Length)
            $writer.Write([UInt32]22)
            $writer.Write($PngBytes)
        } finally {
            $writer.Dispose()
        }
    } finally {
        $fileStream.Dispose()
    }
}

$resolvedRepoRoot = Get-EffectiveRepoRoot -RequestedRepoRoot $RepoRoot
$svgPath = if (-not [string]::IsNullOrWhiteSpace($SourceSvg)) {
    if ([System.IO.Path]::IsPathRooted($SourceSvg)) { $SourceSvg } else { Join-Path $resolvedRepoRoot $SourceSvg }
} else {
    Join-Path $resolvedRepoRoot "assets\icon.svg"
}

if (-not (Test-Path -LiteralPath $svgPath)) {
    Write-Host "Skipping Windows icon generation because the SVG source was not found: $svgPath" -ForegroundColor Yellow
    exit 0
}

$targetDir = if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
    if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $resolvedRepoRoot $OutputDir }
} else {
    Join-Path $resolvedRepoRoot "bin"
}

if (-not (Test-Path -LiteralPath $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir | Out-Null
}

$embeddedPng = Get-EmbeddedPngBytes -SvgPath $svgPath
$resizedPng = New-ResizedPngBytes -SourceBytes $embeddedPng -Size 256

$pngTarget = Join-Path $targetDir "syncpss-icon.png"
$icoTarget = Join-Path $targetDir "syncpss-icon.ico"
$svgTarget = Join-Path $targetDir "syncpss-icon.svg"

[System.IO.File]::WriteAllBytes($pngTarget, $resizedPng)
Write-IcoFromPng -PngBytes $resizedPng -IcoPath $icoTarget
[System.IO.File]::Copy($svgPath, $svgTarget, $true)

Write-Host "Generated Windows icon assets:" -ForegroundColor Green
Write-Host "  $pngTarget"
Write-Host "  $icoTarget"
Write-Host "  $svgTarget"
