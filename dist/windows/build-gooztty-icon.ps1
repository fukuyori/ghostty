<#
.SYNOPSIS
    Builds the Gooztty application icon from the selected ghoultty artwork.

.DESCRIPTION
    Crops the transparent margin of ghoultty-icon-candidate.png, centers the
    artwork on a square canvas, scales it to every Windows icon size with
    high-quality bicubic filtering, and packs the sizes into an ICO with
    PNG-compressed entries (supported since Windows Vista).

    The whole artwork becomes unreadable at taskbar sizes, so sizes up to
    -SmallMaxSize use a square crop around the hood and face instead
    (-SmallCrop, in source pixels: x, y, side), filling the icon.

    The output keeps the upstream file name ghostty.ico, which the resource
    script, the installer and the toast icon reference
    (docs/windows-rebranding-plan.md, Section 1.1).
#>
param(
    # The selected artwork (1254 px, transparent background).
    [string]$Source = (Join-Path $PSScriptRoot 'ghoultty-icon-candidate.png'),
    # The icon to write.
    [string]$Output = (Join-Path $PSScriptRoot 'ghostty.ico'),
    # Transparent margin around the artwork, as a fraction of the icon size.
    [double]$Margin = 0.02,
    # Largest size drawn from the crop instead of the whole artwork.
    [int]$SmallMaxSize = 48,
    # Square crop for the small sizes: x, y and side in source pixels.
    [int[]]$SmallCrop = @(260, 300, 500)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Returns the bounds of the pixels whose alpha is not zero.
function Get-OpaqueBounds([System.Drawing.Bitmap]$bmp) {
    $rect = [System.Drawing.Rectangle]::new(0, 0, $bmp.Width, $bmp.Height)
    $data = $bmp.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $bytes = [byte[]]::new($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    } finally {
        $bmp.UnlockBits($data)
    }
    $left = $bmp.Width; $top = $bmp.Height; $right = -1; $bottom = -1
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $row = $y * $data.Stride
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            if ($bytes[$row + $x * 4 + 3] -ne 0) {
                if ($x -lt $left) { $left = $x }
                if ($x -gt $right) { $right = $x }
                if ($y -lt $top) { $top = $y }
                if ($y -gt $bottom) { $bottom = $y }
            }
        }
    }
    if ($right -lt 0) { throw "The source image is fully transparent: $Source" }
    return [System.Drawing.Rectangle]::new($left, $top, $right - $left + 1, $bottom - $top + 1)
}

function Render-Png([System.Drawing.Bitmap]$src, [System.Drawing.Rectangle]$bounds, [double]$margin, [int]$size, [string]$file) {
    $bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.PixelOffsetMode = 'HighQuality'
        $g.CompositingQuality = 'HighQuality'
        $g.SmoothingMode = 'AntiAlias'
        $inner = $size * (1.0 - 2.0 * $margin)
        $scale = $inner / [Math]::Max($bounds.Width, $bounds.Height)
        $w = $bounds.Width * $scale; $h = $bounds.Height * $scale
        $dest = [System.Drawing.RectangleF]::new(($size - $w) / 2.0, ($size - $h) / 2.0, $w, $h)
        $attr = [System.Drawing.Imaging.ImageAttributes]::new()
        $attr.SetWrapMode('TileFlipXY')
        $g.DrawImage($src, [System.Drawing.Rectangle]::Round($dest), $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height, 'Pixel', $attr)
        $attr.Dispose()
    } finally {
        $g.Dispose()
    }
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $file
}

# Writes an ICO whose entries are PNG-compressed images.
function Write-Ico([string[]]$pngFiles, [int[]]$sizes, [string]$icoFile) {
    # The leading comma keeps each byte[] as one element instead of unrolling it.
    $datas = @($pngFiles | ForEach-Object { , [System.IO.File]::ReadAllBytes($_) })
    $ms = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($ms)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$datas.Count)
    $offset = 6 + 16 * $datas.Count
    for ($i = 0; $i -lt $datas.Count; $i++) {
        $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$datas[$i].Length); $w.Write([uint32]$offset)
        $offset += $datas[$i].Length
    }
    foreach ($d in $datas) { $w.Write($d) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($icoFile, $ms.ToArray())
    $w.Dispose(); $ms.Dispose()
}

$sizesDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gooztty-icon-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $sizesDir | Out-Null
$src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Source).Path)
try {
    $bounds = Get-OpaqueBounds $src
    if ($SmallCrop.Count -ne 3) { throw "-SmallCrop takes x, y and side." }
    $crop = [System.Drawing.Rectangle]::new($SmallCrop[0], $SmallCrop[1], $SmallCrop[2], $SmallCrop[2])
    if (-not ([System.Drawing.Rectangle]::new(0, 0, $src.Width, $src.Height)).Contains($crop)) {
        throw "-SmallCrop lies outside the $($src.Width)x$($src.Height) source."
    }
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $files = foreach ($s in $sizes) {
        $file = Join-Path $sizesDir "gooztty-$s.png"
        if ($s -le $SmallMaxSize) { Render-Png $src $crop 0.0 $s $file } else { Render-Png $src $bounds $Margin $s $file }
    }
    Write-Ico $files $sizes $Output
} finally {
    $src.Dispose()
}
Write-Output "Wrote $Output from $Source (artwork bounds $($bounds.Width)x$($bounds.Height)); per-size PNGs in $sizesDir"
