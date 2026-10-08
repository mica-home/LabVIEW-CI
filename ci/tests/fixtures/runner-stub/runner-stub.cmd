@echo off
rem ============================================================================
rem runner-stub.cmd - a REAL executable stand-in for gitea-runner(.exe).
rem
rem ci/runner/setup-runner.ps1 resolves the binary via -BinaryPath (the only
rem injection seam the tests need). This .cmd is what gets launched (a .cmd is a
rem real process, so exit codes and stdout/stderr are the real CLI contract) and
rem it forwards to runner-stub.ps1, which records the argv (token value redacted,
rem SHA-256 of it recorded instead), creates .runner in the current directory on
rem a successful "register" and exits with %STUB_EXIT_CODE%.
rem
rem Nothing here talks to the network; the Gitea URL is only ever a string.
rem ============================================================================
pwsh -NoProfile -NonInteractive -File "%~dp0runner-stub.ps1" %*
set "RC=%ERRORLEVEL%"
exit /b %RC%
