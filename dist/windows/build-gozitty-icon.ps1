<#
.SYNOPSIS
    Renders the finished Gozitty icon (based on Antigravity's "kaiju 4"
    candidate) at every Windows icon size and packs them into an ICO.

    Sizes 64 px and up use the detailed artwork (scale texture, shadow,
    highlight). Sizes 48 px and below use a simplified variant drawn directly
    at the target size: no texture, no shadow, a larger container, and the
    artwork scaled up so the spikes and the "G" survive.
#>
param(
    # Receives gozitty-icon-candidate.png (1024 px master) and gozitty-candidate.ico.
    [string]$OutDir = $PSScriptRoot,
    # Receives the per-size PNGs packed into the ICO.
    [string]$SizesDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'gozitty-icon-sizes')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RoundedRectPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = $r * 2.0
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function PF([float]$x, [float]$y) { [System.Drawing.PointF]::new($x, $y) }
function ARGB([int]$a, [int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

function Fill-Gradient($g, $path, $p1, $p2, $c1, $c2) {
    $br = [System.Drawing.Drawing2D.LinearGradientBrush]::new($p1, $p2, $c1, $c2)
    $g.FillPath($br, $path)
    $br.Dispose()
}

function Draw-Chevron($g, [float]$apexX, [float]$apexY, [float]$len, [float]$width, $color) {
    $dx = $len * [Math]::Cos([Math]::PI / 4); $dy = $len * [Math]::Sin([Math]::PI / 4)
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddLine($apexX - $dx, $apexY - $dy, $apexX, $apexY)
    $path.AddLine($apexX, $apexY, $apexX - $dx, $apexY + $dy)
    $pen = [System.Drawing.Pen]::new($color, $width)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $g.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
}

# Draws the icon in 1024x1024 design coordinates.
function Draw-Icon($g, [bool]$small) {
    if ($small) {
        $bx = 24.0; $by = 24.0; $bw = 976.0; $bh = 976.0; $br = 210.0
    } else {
        $bx = 92.0; $by = 92.0; $bw = 840.0; $bh = 840.0; $br = 196.0
        # Soft drop shadow (detailed sizes only).
        for ($i = 16; $i -ge 1; $i--) {
            $s = $i * 2.6; $oy = $i * 2.5 + 12.0
            $sp = New-RoundedRectPath ($bx - $s) ($by - $s + $oy) ($bw + $s * 2) ($bh + $s * 2) ($br + $s)
            $sb = [System.Drawing.SolidBrush]::new((ARGB ([int][Math]::Min(45, [Math]::Max(1, 28.0 / $i))) 0 0 0))
            $g.FillPath($sb, $sp); $sb.Dispose(); $sp.Dispose()
        }
    }

    $box = New-RoundedRectPath $bx $by $bw $bh $br
    Fill-Gradient $g $box (PF $bx $by) (PF $bx ($by + $bh)) (ARGB 255 18 26 26) (ARGB 255 9 13 15)

    if (-not $small) {
        # Diamond scale texture (detailed sizes only).
        $g.SetClip($box)
        $pen = [System.Drawing.Pen]::new((ARGB 20 0 255 170), 1.2)
        $fill = [System.Drawing.SolidBrush]::new((ARGB 6 0 255 170))
        $sx = 36.0; $sy = 24.0
        for ($y = $by; $y -lt ($by + $bh); $y += $sy) {
            $row = [int][Math]::Floor(($y - $by) / $sy)
            $off = if ($row % 2 -eq 0) { 0.0 } else { $sx / 2.0 }
            for ($x = $bx - $sx; $x -lt ($bx + $bw + $sx); $x += $sx) {
                $cx = $x + $off
                $d = [System.Drawing.Drawing2D.GraphicsPath]::new()
                $d.AddPolygon([System.Drawing.PointF[]]@((PF $cx ($y - $sy * 0.75)), (PF ($cx + $sx * 0.42) $y), (PF $cx ($y + $sy * 0.75)), (PF ($cx - $sx * 0.42) $y)))
                $g.FillPath($fill, $d); $g.DrawPath($pen, $d); $d.Dispose()
            }
        }
        $pen.Dispose(); $fill.Dispose()
        $g.ResetClip()
    }

    $borderWidth = if ($small) { 30.0 } else { 3.0 }
    $border = [System.Drawing.Pen]::new((ARGB 200 0 255 180), $borderWidth)
    $border.Alignment = 'Inset'
    $g.DrawPath($border, $box); $border.Dispose()

    if (-not $small) {
        $hl = [System.Drawing.Pen]::new((ARGB 60 255 255 255), 2.5)
        $hp = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $hp.AddArc($bx + 4, $by + 4, $br * 2, $br * 2, 180, 90)
        $hp.AddLine($bx + $br, $by + 4, $bx + $bw - $br, $by + 4)
        $hp.AddArc($bx + $bw - $br * 2 - 4, $by + 4, $br * 2, $br * 2, 270, 90)
        $g.DrawPath($hl, $hp); $hl.Dispose(); $hp.Dispose()
    }
    $box.Dispose()

    # Small sizes: enlarge the artwork around its visual centre.
    $state = $g.Save()
    if ($small) {
        $g.TranslateTransform(492, 470)
        $g.ScaleTransform(1.16, 1.16)
        $g.TranslateTransform(-492, -470)
    }

    # Plate 1: top bar with three enlarged spikes (taller and wider than the candidate).
    $p1 = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $p1.AddPolygon([System.Drawing.PointF[]]@(
        (PF 330 260),
        (PF 380 260), (PF 422 150), (PF 464 260),
        (PF 492 260), (PF 534 150), (PF 576 260),
        (PF 604 260), (PF 646 150), (PF 688 260),
        (PF 750 260), (PF 750 360), (PF 370 360), (PF 320 410), (PF 235 345)))
    Fill-Gradient $g $p1 (PF 235 150) (PF 750 360) (ARGB 255 0 255 170) (ARGB 255 0 210 210)
    $p1.Dispose()

    # Plate 2: left spine.
    $p2 = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $p2.AddPolygon([System.Drawing.PointF[]]@((PF 230 370), (PF 315 435), (PF 315 600), (PF 230 645)))
    Fill-Gradient $g $p2 (PF 230 370) (PF 315 645) (ARGB 255 0 230 200) (ARGB 255 0 180 230)
    $p2.Dispose()

    # Plate 3: bottom bar and spur.
    $p3 = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $p3.AddPolygon([System.Drawing.PointF[]]@((PF 235 670), (PF 320 625), (PF 370 674), (PF 635 674), (PF 635 520), (PF 750 520), (PF 750 774), (PF 330 774)))
    Fill-Gradient $g $p3 (PF 235 520) (PF 750 774) (ARGB 255 0 185 230) (ARGB 255 0 140 245)
    $p3.Dispose()

    # Prompt ">>" and cursor; strokes are heavier at small sizes.
    $cw = if ($small) { 56.0 } else { 42.0 }
    Draw-Chevron $g 425 512 88 $cw (ARGB 255 255 255 255)
    Draw-Chevron $g 520 512 88 $cw (ARGB 255 0 255 170)

    $cur = New-RoundedRectPath 575 455 58 114 10
    Fill-Gradient $g $cur (PF 575 455) (PF 633 569) (ARGB 255 0 245 255) (ARGB 255 0 165 255)
    if (-not $small) {
        $cb = [System.Drawing.Pen]::new((ARGB 220 255 255 255), 2.5)
        $g.DrawPath($cb, $cur); $cb.Dispose()
    }
    $cur.Dispose()
    $g.Restore($state)
}

function Render-Png([int]$size, [bool]$small, [string]$file) {
    $bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.ScaleTransform($size / 1024.0, $size / 1024.0)
    Draw-Icon $g $small
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $file
}

# Writes an ICO whose entries are PNG-compressed images (supported since Windows Vista).
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

New-Item -ItemType Directory -Force $OutDir, $SizesDir | Out-Null
Render-Png 1024 $false (Join-Path $OutDir 'gozitty-icon-candidate.png') | Out-Null

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$files = foreach ($s in $sizes) {
    Render-Png $s ($s -le 48) (Join-Path $SizesDir "gozitty-icon-$s.png")
}
Write-Ico $files $sizes (Join-Path $OutDir 'gozitty-candidate.ico')
Write-Output "Generated gozitty-icon-candidate.png and gozitty-candidate.ico in $OutDir; per-size PNGs in $SizesDir"
