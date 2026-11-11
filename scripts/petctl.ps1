<#
Send one command to the desktop pet on Windows. Silent no-op when the pet is
not running, so it is safe to call from hooks and build scripts.

  petctl.ps1 [-n NAME] ok | fail | work | done | climb | sleep | wake | meow | say TEXT | goto X | quit
  petctl.ps1 [-n NAME] run CMD...   run CMD, then send ok or fail based on its exit code

The pet listens on \\.\pipe\pet; one started with --name NAME on
\\.\pipe\pet-NAME (or set PET_NAME). A busy or missing pipe drops the
command instead of waiting.
#>
$ErrorActionPreference = 'Stop'
$name = $env:PET_NAME
$rest = @($args)
if ($rest.Count -ge 2 -and $rest[0] -eq '-n') { $name = $rest[1]; $rest = @($rest | Select-Object -Skip 2) }
$pipe = if ($name) { "pet-$name" } else { 'pet' }

function Send-Pet([string]$line) {
    try {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipe, [System.IO.Pipes.PipeDirection]::Out)
        $client.Connect(0)  # no waiting: no pet, or busy with another sender
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`n")
        $client.Write($bytes, 0, $bytes.Length)
        $client.Flush()
    } catch {
    } finally {
        if ($client) { $client.Dispose() }
    }
}

if ($rest.Count -eq 0 -or $rest[0] -in @('-h', '--help')) {
    Get-Content $PSCommandPath -TotalCount 11 | Select-Object -Skip 1 | ForEach-Object { $_ }
    exit 0
}
if ($rest[0] -eq 'run') {
    if ($rest.Count -lt 2) { Write-Error 'petctl run: missing command'; exit 2 }
    Send-Pet 'work'
    $cmd = $rest[1]
    $cmdArgs = @($rest | Select-Object -Skip 2)
    & $cmd @cmdArgs
    $status = $LASTEXITCODE
    if ($status -eq 0 -or ($null -eq $status -and $?)) { Send-Pet 'ok' } else { Send-Pet 'fail' }
    exit $status
}
Send-Pet ($rest -join ' ')
