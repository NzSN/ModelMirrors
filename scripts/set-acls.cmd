@echo off
rem Restrict the certs directory to SYSTEM and Administrators.
rem Run from an elevated cmd; paths are native Windows (no MSYS mangling).
if not exist D:\ModelMirrors\certs ( echo CERTS_DIR_MISSING & exit /b 3 )
icacls D:\ModelMirrors\certs /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"
if errorlevel 1 ( echo ACLS_FAILED & exit /b 4 )
echo ACLS_DONE 0
