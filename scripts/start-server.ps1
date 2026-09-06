param(
    [Parameter(Mandatory = $true)][string]$Config,
    [ValidateRange(1, 65535)][int]$Port = 4567,
    [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'simple-rag')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$configPath = (Resolve-Path -LiteralPath $Config).Path
$serverPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../exe/run-server')).Path
$location = Get-Location
if ($location.Provider.Name -ne 'FileSystem') { throw 'Run this helper from a filesystem directory.' }
$workingPath = $location.ProviderPath
$rubyCommand = Get-Command ruby -CommandType Application -ErrorAction Stop
$configDigest = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
$serverUrl = "http://127.0.0.1:${Port}"

Add-Type -AssemblyName System.Net.Http
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$http = [System.Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromMilliseconds(750)

function Get-ServerHealth {
    try {
        $body = $http.GetStringAsync("${serverUrl}/health").GetAwaiter().GetResult()
        return ($body | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-MatchingHealth($health) {
    if ($null -eq $health) { return $false }
    if (-not $health.PSObject.Properties['config'] -or -not $health.PSObject.Properties['configDigest']) {
        return $false
    }
    $servedPath = [IO.Path]::GetFullPath($health.config).Replace('/', '\')
    return $servedPath -eq $configPath.Replace('/', '\') -and $health.configDigest -eq $configDigest
}

try {
    if (Test-MatchingHealth (Get-ServerHealth)) {
        Write-Output "Matching server already running at $serverUrl"
        return
    }

    # Never replace an unrelated server or a server with stale configuration.
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } catch { throw "Port $Port is occupied by a non-matching server. Stop its owner or choose another -Port." }
    finally { $listener.Stop() }

    $logPath = [IO.Path]::GetFullPath($LogDirectory)
    $null = New-Item -ItemType Directory -Path $logPath -Force
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $stdoutPath = Join-Path $logPath "server-${Port}-${stamp}.stdout.log"
    $stderrPath = Join-Path $logPath "server-${Port}-${stamp}.stderr.log"
    $serverArguments = @('"{0}"' -f $serverPath) + @('"{0}"' -f $configPath) + @('--bind', '127.0.0.1', '--port', $Port)
    $serverProcess = Start-Process -FilePath $rubyCommand.Source -ArgumentList $serverArguments `
        -WorkingDirectory $workingPath -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $serverProcess.Refresh()
            if ($serverProcess.HasExited) { throw "Server exited with code $($serverProcess.ExitCode). See $stderrPath and $stdoutPath" }
            if (Test-MatchingHealth (Get-ServerHealth)) {
                Write-Output "Server running at $serverUrl (PID $($serverProcess.Id))"
                Write-Output "Config: $configPath"
                Write-Output "Logs: $logPath"
                return
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "Server did not become ready within 30 seconds. See $stderrPath and $stdoutPath"
    } catch {
        if (-not $serverProcess.HasExited) { $serverProcess.Kill(); $serverProcess.WaitForExit() }
        throw
    } finally {
        $serverProcess.Dispose()
    }
} finally {
    $http.Dispose()
}
