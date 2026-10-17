<#
.SYNOPSIS
Prints a small colored sample for testing HTML clipboard copy in Ghostty.

.DESCRIPTION
Run this script in the Ghostty window under test. Select only the three
output lines, then use the configured copy_to_clipboard:html or :mixed key.
Use -TestOsc52 to send a separate OSC 52 clipboard-write probe.

.PARAMETER TestOsc52
Write the known OSC 52 test value to the clipboard after printing the sample.

.NOTES
This script prepares terminal output only; Ghostty performs the clipboard
copy when the user invokes the configured key binding.
#>

param(
    [switch]$TestOsc52
)

Write-Host "HTML clipboard test: 日本語"
Write-Host "Red text" -ForegroundColor Red
Write-Host "Second line"

if ($TestOsc52) {
    $value = "OSC52 clipboard regression"
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
    [Console]::Write(([string][char]0x1B) + "]52;c;$payload" + [char]0x07)
}
