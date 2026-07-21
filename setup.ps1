param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $SetupArgs
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bash = Get-Command bash -ErrorAction SilentlyContinue

if (-not $Bash) {
    throw 'Could not find bash. Install Git Bash or WSL.'
}

function ConvertTo-BashPath([string] $WindowsPath) {
    $resolved = (Resolve-Path -LiteralPath $WindowsPath).Path
    $uname = (& $Bash.Source -lc 'uname -s' 2>$null).Trim()
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    $rest = $resolved.Substring(3).Replace('\', '/')

    if ($uname -like 'MINGW*' -or $uname -like 'MSYS*' -or $uname -like 'CYGWIN*') {
        return "/$drive/$rest"
    }

    return "/mnt/$drive/$rest"
}

function HasArg([string[]] $Args, [string] $Name) {
    return $Args -contains $Name
}

if (-not (HasArg $SetupArgs '--ip') -and -not (HasArg $SetupArgs '-h') -and -not (HasArg $SetupArgs '--help')) {
    $detectedIp = Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1 -ExpandProperty IPv4Address |
        Select-Object -ExpandProperty IPAddress

    if ($detectedIp) {
        $SetupArgs = @($SetupArgs) + @('--ip', $detectedIp)
    }
}

$TargetScript = ConvertTo-BashPath (Join-Path $ScriptDir 'setup.sh')
& $Bash.Source $TargetScript @SetupArgs
exit $LASTEXITCODE