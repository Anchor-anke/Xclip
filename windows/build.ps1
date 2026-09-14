param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [switch]$SkipSmoke
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = $PSScriptRoot
$project = Join-Path $projectRoot 'Xclip.Windows/Xclip.Windows.csproj'
$tests = Join-Path $projectRoot 'Xclip.Core.Tests/Xclip.Core.Tests.csproj'
$outputRoot = Join-Path $projectRoot 'artifacts'
$publishDir = Join-Path $outputRoot $Runtime

Push-Location $projectRoot
try {
    dotnet run --project $tests -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
    # Recreate only this generated architecture directory; user data lives in LocalAppData.
    if (Test-Path $publishDir) { Remove-Item -LiteralPath $publishDir -Recurse -Force }
    dotnet publish $project -c Release -r $Runtime --self-contained true -p:PublishSingleFile=false -p:PublishReadyToRun=false -o $publishDir
    if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
    if (-not (Test-Path (Join-Path $publishDir 'Xclip.exe'))) { throw 'Xclip.exe was not generated.' }
    Copy-Item (Join-Path $projectRoot 'PACKAGE-README.txt') (Join-Path $publishDir 'README.txt')
    $hostArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $matchingHost = ($Runtime -eq 'win-x64' -and $hostArchitecture -eq 'X64') -or ($Runtime -eq 'win-arm64' -and $hostArchitecture -eq 'Arm64')
    if (-not $SkipSmoke -and $env:OS -eq 'Windows_NT' -and $matchingHost) {
        $env:XCLIP_SMOKE_OUTPUT = Join-Path $outputRoot ('smoke-' + $Runtime)
        $smoke = Start-Process -FilePath (Join-Path $publishDir 'Xclip.exe') -ArgumentList '--smoke-test' -Wait -PassThru
        if ($smoke.ExitCode -ne 0) { throw 'Windows UI smoke failed.' }
    }
    elseif (-not $SkipSmoke) { Write-Warning 'Native UI smoke requires a Windows host with the matching architecture.' }
    $zip = Join-Path $outputRoot ('Xclip-Windows-preview-' + $Runtime + '.zip')
    Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zip -Force
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(($zip + '.sha256'), ($hash + '  ' + [System.IO.Path]::GetFileName($zip) + "`n"))
    Write-Output ('Built: ' + $zip)
}
finally { Pop-Location }
