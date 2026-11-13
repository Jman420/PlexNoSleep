# PlexNoSleep
PowerShell Script to prevent Windows from sleeping while Plex is playing audio-only media

## Dependencies
* NAudio.Wasapi : https://www.nuget.org/packages/NAudio.Wasapi/
* NAudio.Core : https://www.nuget.org/packages/NAudio.Core/

## Installation
* Download the Prevent-SleepDuringPlexAudio.ps1 script
* Download and extract the appropriate DLLs for the dependencies listed above to the same directory as the script

## Usage
* See the PowerShell script file's header for command line parameters.
* When audio stops being detected, the script resets Windows' system idle timer before releasing the sleep block. A 5-minute sleep timeout therefore starts again when the block is released, rather than allowing immediate sleep. Detection can take up to `PollIntervalSeconds` (20 seconds by default).
* The display timeout and power-plan settings are unchanged. Other activity or applications can still delay sleep.

## Regression test
Run `pwsh -NoProfile -File ./tests/Clear-SleepBlock.Tests.ps1` in a fresh PowerShell process. This uses a fake Windows API to check the reset/release order and error handling; actual sleep timing must be checked on Windows.

## AI Disclosure
Written by Google Gemini and GitHub Copilot.  All code reviewed and approved by a human.
