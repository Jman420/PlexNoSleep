<#
.SYNOPSIS
    Launches Plex for Windows, then prevents Windows 11 from sleeping while
    it's actively outputting audio - exiting automatically once Plex closes.

.DESCRIPTION
    1. If $ProcessName isn't already running, launches Plex from $PlexPath.
    2. Waits (up to $LaunchTimeoutSeconds) for $ProcessName to appear - this
       matters because some launcher .exe files spawn a differently-named
       child process and then exit themselves, so we confirm the real
       process is up rather than trusting the launched handle directly.
    3. Every $PollIntervalSeconds, checks Plex's WASAPI session peak meter.
       If audio is audible, blocks sleep (ES_SYSTEM_REQUIRED only - the
       display can still turn off/lock normally). Releases the block the
       moment audio stops.
    4. As soon as $ProcessName is no longer running, releases any sleep
       block and exits.

.REQUIREMENTS
    NAudio.Core.dll and NAudio.Wasapi.dll (v2.x) sitting next to this script,
    or point -NAudioDllFolder at wherever you put them.
	
	https://www.nuget.org/packages/NAudio.Wasapi/
	https://www.nuget.org/packages/NAudio.Core/

.PARAMETER PlexPath
    Full path to the Plex executable or a shortcut you'd normally launch it
    from, e.g. "C:\Users\you\AppData\Local\Plex\Plex.exe".

.PARAMETER PlexArgs
    Optional command-line arguments to pass when launching Plex.

.PARAMETER ProcessName
    Name (no .exe) of the process to MONITOR once running. This is the name
    used both to detect "Plex has started" after launch and "Plex has
    closed" in the main loop. Verify with:
        Get-Process | Where-Object Name -like '*plex*'
    (run this once with Plex already open, since the running process name
    can differ from the launcher exe's name).

.PARAMETER LaunchTimeoutSeconds
    How long to wait for $ProcessName to appear after launching before
    giving up with an error.

.PARAMETER PollIntervalSeconds
    How often to check the audio peak / whether Plex is still running.

.PARAMETER PeakThreshold
    Minimum peak meter value (0.0-1.0) to count as "audible".

.PARAMETER NAudioDllFolder
    Folder containing NAudio.Core.dll and NAudio.Wasapi.dll.

.EXAMPLE
    .\Prevent-SleepDuringPlexAudio.ps1 -PlexPath "C:\Users\you\AppData\Local\Plex\Plex.exe" -ProcessName "PlexHTPC"
#>

param(
    [string]$PlexPath = "C:\Program Files\Plex\Plex\Plex.exe",  # default install path for all users
    [string]$PlexArgs = "",
    [string]$ProcessName = "Plex",  # default process name for Plex for Windows

    [int]$LaunchTimeoutSeconds = 30,
    [int]$PollIntervalSeconds = 20,
    [double]$PeakThreshold = 0.001,
    [string]$NAudioDllFolder = $PSScriptRoot
)

# --- Load NAudio (Core must load before Wasapi, which depends on it) ---
$coreDll   = Join-Path $NAudioDllFolder "NAudio.Core.dll"
$wasapiDll = Join-Path $NAudioDllFolder "NAudio.Wasapi.dll"

foreach ($dll in @($coreDll, $wasapiDll)) {
    if (-not (Test-Path $dll)) {
        throw "Required file not found: $dll`nCopy NAudio.Core.dll and NAudio.Wasapi.dll next to this script (see the .REQUIREMENTS block in the script header)."
    }
}
Add-Type -Path $coreDll
Add-Type -Path $wasapiDll

# --- P/Invoke for SetThreadExecutionState ---
Add-Type -Namespace Native -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

$ES_CONTINUOUS      = [Convert]::ToUInt32("80000000", 16)
$ES_SYSTEM_REQUIRED = [Convert]::ToUInt32("00000001", 16)
# ES_DISPLAY_REQUIRED intentionally omitted - audio-only, so the display
# is allowed to turn off/lock on its normal schedule.

function Get-PlexAudioPeak {
    param([string]$ProcName)

    $procs = Get-Process -Name $ProcName -ErrorAction SilentlyContinue
    if (-not $procs) { return $null }   # not running
    $pids = $procs.Id

    $enumerator = New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
    try {
        $device = $enumerator.GetDefaultAudioEndpoint(
            [NAudio.CoreAudioApi.DataFlow]::Render,
            [NAudio.CoreAudioApi.Role]::Multimedia
        )

        $sessions = $device.AudioSessionManager.Sessions
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            $session = $sessions.Item($i)
            if ($pids -contains $session.GetProcessID) {
                return $session.AudioMeterInformation.MasterPeakValue
            }
        }
        return 0.0   # running, but no active render session right now
    }
    finally {
        $enumerator.Dispose()
    }
}

function Start-PlexIfNeeded {
    param(
        [string]$PlexPath,
        [string]$PlexArgs,
        [string]$ProcessName,
        [int]$TimeoutSeconds
    )

    $existing = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "$ProcessName is already running (PID $(($existing.Id) -join ', ')) - not relaunching."
        return
    }

    if (-not (Test-Path $PlexPath)) {
        throw "PlexPath not found: $PlexPath"
    }

    Write-Host "Launching Plex: $PlexPath $PlexArgs"
    if ([string]::IsNullOrWhiteSpace($PlexArgs)) {
        Start-Process -FilePath $PlexPath | Out-Null
    }
    else {
        Start-Process -FilePath $PlexPath -ArgumentList $PlexArgs | Out-Null
    }

    # Poll for the real process name rather than trusting the launched
    # handle, in case Plex's launcher exe hands off to a child process.
    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
            Write-Host "$(Get-Date -Format T)  $ProcessName is now running."
            return
        }
        Start-Sleep -Seconds 1
        $waited++
    }

    throw "Timed out after $TimeoutSeconds s waiting for process '$ProcessName' to appear after launching $PlexPath.`nCheck -ProcessName matches the actual running process: Get-Process | Where-Object Name -like '*plex*'"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Start-PlexIfNeeded -PlexPath $PlexPath -PlexArgs $PlexArgs -ProcessName $ProcessName -TimeoutSeconds $LaunchTimeoutSeconds

Write-Host "Monitoring '$ProcessName' for audible playback (Ctrl+C to stop early)..."
$currentlyBlocking = $false

try {
    while ($true) {
        $peak = Get-PlexAudioPeak -ProcName $ProcessName

        if ($null -eq $peak) {
            Write-Host "$(Get-Date -Format T)  $ProcessName is no longer running - exiting."
            break
        }

        $isAudible = $peak -gt $PeakThreshold

        if ($isAudible -and -not $currentlyBlocking) {
            [Native.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
            $currentlyBlocking = $true
            Write-Host "$(Get-Date -Format T)  Plex audio detected (peak=$peak) - blocking sleep."
        }
        elseif (-not $isAudible -and $currentlyBlocking) {
            [Native.Power]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
            $currentlyBlocking = $false
            Write-Host "$(Get-Date -Format T)  Plex audio stopped - normal sleep behavior restored."
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
finally {
    [Native.Power]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    Write-Host "Sleep block released. Exiting."
}
