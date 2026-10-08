@echo off
rem ============================================================================
rem vipm-stub.cmd - a REAL executable stand-in for vipm.exe (VI Package Manager CLI).
rem
rem ci/bootstrap-deps.ps1 resolves the CLI via -VipmPath (the only injection seam
rem the tests need). This .cmd is what gets launched (a .cmd is a real process, so
rem exit codes and stdout/stderr are the real CLI contract) and it forwards to
rem vipm-stub.ps1, which records the received argv, replays the fixture files
rem ($STUB_LIST_FILE / $STUB_INSTALL_OUTPUT_FILE) and exits with %STUB_EXIT_CODE%.
rem
rem Purpose: the automated tests must NEVER call the real
rem "C:\Program Files\JKI\VI Package Manager\support\vipm.exe" - that would touch a
rem developer machine with 18 real packages installed. Nothing here talks to VIPM,
rem the network, or any VIPM state; it is fixture replay only.
rem ============================================================================
pwsh -NoProfile -NonInteractive -File "%~dp0vipm-stub.ps1" %*
set "RC=%ERRORLEVEL%"
exit /b %RC%
