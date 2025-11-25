@echo off

:: Enter HOST, USER, PASS for raspberry Pi
set HOST=
set USER=
set PASS=


:: Main
set SHARE1=USB1
set SHARE2=USB2

set DRIVE1=Z:
set DRIVE2=Y:

echo Unmapping existing drives (if any)...
net use %DRIVE1% /delete /yes >nul 2>&1
net use %DRIVE2% /delete /yes >nul 2>&1

echo Mapping %DRIVE1% to \\%HOST%\%SHARE1% ...
net use %DRIVE1% \\%HOST%\%SHARE1% /user:%USER% %PASS% /persistent:yes

echo Mapping %DRIVE2% to \\%HOST%\%SHARE2% ...
net use %DRIVE2% \\%HOST%\%SHARE2% /user:%USER% %PASS% /persistent:yes

echo Done.
pause
