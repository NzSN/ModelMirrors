@echo off
rem Install ModelMirrors as a Windows service via NSSM.
rem Run from an elevated cmd; paths are native Windows (no MSYS mangling).
rem Prereqs: bin\ModelMirrors.exe, tools\nssm.exe, and certs from gen-certs.sh
rem (D:\ModelMirrors\certs\server.crt|key, ca.crt).
set BIN=D:\ModelMirrors\bin\ModelMirrors.exe
if not exist "%BIN%" ( echo MODELMIRRORS_EXE_MISSING & exit /b 3 )
if not exist D:\ModelMirrors\tools\nssm.exe ( echo NSSM_MISSING & exit /b 2 )

rem NSSM will not create parent dirs for log files, and Java needs a
rem writable TEMP (the env block below points TEMP/TMP at tmp).
if not exist D:\ModelMirrors\logs md D:\ModelMirrors\logs
if not exist D:\ModelMirrors\tmp  md D:\ModelMirrors\tmp

D:\ModelMirrors\tools\nssm.exe install ModelMirrors "%BIN%" || ( echo NSSM_INSTALL_FAILED & exit /b 4 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppDirectory "D:\ModelMirrors" || ( echo NSSM_SET_FAILED AppDirectory & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppParameters "--server 8999 --tls --cert D:\ModelMirrors\certs\server.crt --key D:\ModelMirrors\certs\server.key --ca D:\ModelMirrors\certs\ca.crt --jobs 4" || ( echo NSSM_SET_FAILED AppParameters & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppExit Default Restart || ( echo NSSM_SET_FAILED AppExit & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppRestartDelay 5000 || ( echo NSSM_SET_FAILED AppRestartDelay & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppStdout "D:\ModelMirrors\logs\service.out.log" || ( echo NSSM_SET_FAILED AppStdout & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppStderr "D:\ModelMirrors\logs\service.err.log" || ( echo NSSM_SET_FAILED AppStderr & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppRotateFiles 1 || ( echo NSSM_SET_FAILED AppRotateFiles & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppRotateBytes 10485760 || ( echo NSSM_SET_FAILED AppRotateBytes & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppEnvironmentExtra "APALACHE_MC=D:\ModelMirrors\bin\apalache-mc.exe" "TEMP=D:\ModelMirrors\tmp" "TMP=D:\ModelMirrors\tmp" "LC_ALL=C.UTF-8" "LANG=C.UTF-8" "JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8 -Duser.language=en" "PATH=C:\Windows\System32;C:\Windows;C:\Program Files\Common Files\Oracle\Java\javapath" || ( echo NSSM_SET_FAILED AppEnvironmentExtra & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors Start SERVICE_AUTO_START || ( echo NSSM_SET_FAILED Start & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe set ModelMirrors ObjectName LocalSystem || ( echo NSSM_SET_FAILED ObjectName & exit /b 5 )
D:\ModelMirrors\tools\nssm.exe start ModelMirrors || ( echo NSSM_START_FAILED & exit /b 5 )
echo SERVICE_SETUP_DONE %ERRORLEVEL%
