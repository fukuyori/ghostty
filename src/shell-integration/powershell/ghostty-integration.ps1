# Ghostty PowerShell integration.
# Dot-sourced by Ghostty for interactive PowerShell sessions.

if (-not $global:__ghostty_integration_loaded) {
    $global:__ghostty_saved_prompt = $function:prompt
    $global:__ghostty_integration_loaded = $true
}

function global:prompt {
    $location = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($location.Provider.Name -eq 'FileSystem' -and
        $location.ProviderPath -match '^[A-Za-z]:[\\/]') {
        $uri = [System.Uri]::new($location.ProviderPath).AbsoluteUri
        [System.Console]::Write("$([char]27)]7;$uri$([char]7)")
    }

    if ($global:__ghostty_saved_prompt) {
        & $global:__ghostty_saved_prompt
    } else {
        "PS $location> "
    }
}
