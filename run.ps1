param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $RunArgs
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

$TargetScript = ConvertTo-BashPath (Join-Path $ScriptDir 'run.sh')
& $Bash.Source $TargetScript @RunArgs
exit $LASTEXITCODE