$ErrorActionPreference = 'Stop'

# Load only the helper, avoiding Plex, NAudio, and the real Windows API.
$scriptPath = Join-Path $PSScriptRoot '../Prevent-SleepDuringPlexAudio.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}
$helper = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Clear-SleepBlock'
}, $true)
if ($null -eq $helper) {
    throw 'Clear-SleepBlock was not found.'
}
. ([scriptblock]::Create($helper.Extent.Text))

Add-Type -TypeDefinition @'
namespace Native {
    public static class Power {
        public static readonly System.Collections.Generic.List<uint> Calls =
            new System.Collections.Generic.List<uint>();
        public static int FailOnCall;

        public static uint SetThreadExecutionState(uint flags) {
            Calls.Add(flags);
            return Calls.Count == FailOnCall ? 0u : 0x80000001u;
        }
    }
}
'@

$ES_CONTINUOUS = [Convert]::ToUInt32('80000000', 16)
$ES_SYSTEM_REQUIRED = [uint32]1

Clear-SleepBlock
if ([Native.Power]::Calls.Count -ne 2 -or
    [Native.Power]::Calls[0] -ne $ES_SYSTEM_REQUIRED -or
    [Native.Power]::Calls[1] -ne $ES_CONTINUOUS) {
    throw 'The system idle timer must be reset before releasing the continuous block.'
}

foreach ($failedCall in 1, 2) {
    [Native.Power]::Calls.Clear()
    [Native.Power]::FailOnCall = $failedCall
    $failure = $null
    try {
        Clear-SleepBlock
    }
    catch {
        $failure = $_
    }
    $expectedMessage = if ($failedCall -eq 1) {
        'Failed to reset the system idle timer before releasing the sleep block.'
    }
    else {
        'Failed to release the sleep block after resetting the system idle timer.'
    }
    if ($null -eq $failure -or $failure.Exception.Message -ne $expectedMessage) {
        throw "API failure on call $failedCall must produce a specific error."
    }
    if ([Native.Power]::Calls.Count -ne $failedCall) {
        throw 'A failed timer reset must not be followed by releasing the block.'
    }
}

Write-Host 'PASS: reset before release; reset failure; release failure.'
