@echo off
REM ============================================================================
REM  Run one NeuroEdge testbench in Vivado's simulator (XSIM), from this folder.
REM
REM    run_xsim.bat tb_iir        IIR filter
REM    run_xsim.bat tb_encoder    event encoder
REM    run_xsim.bat tb_event_cov  event-driven covariance
REM    run_xsim.bat tb_ns         Newton-Schulz self-calibration
REM    run_xsim.bat tb_top        whole core, 16 trials (takes a few minutes)
REM
REM  If "xvlog is not recognized", set VIVADO_DIR below to your install folder.
REM ============================================================================
setlocal
set VIVADO_DIR=D:\Installations\xillinx\Vivado\2016.4
set TB=%1
REM Inside Vivado (or its Tcl shell) XILINX_VIVADO already points at the install
if defined XILINX_VIVADO set VIVADO_DIR=%XILINX_VIVADO%
if "%TB%"=="" set TB=tb_top

where xvlog >nul 2>nul
if errorlevel 1 (
    if exist "%VIVADO_DIR%\bin\xvlog.bat" (
        set "PATH=%VIVADO_DIR%\bin;%PATH%"
    ) else (
        echo Cannot find Vivado: no %VIVADO_DIR%\bin\xvlog.bat. Edit VIVADO_DIR at the top of this file.
        exit /b 1
    )
)

cd /d "%~dp0"
set RTL=..\rtl\iir_bandpass.v ..\rtl\event_encoder.v ..\rtl\event_cov.v ..\rtl\drift_monitor.v ..\rtl\backend.v ..\rtl\ns_calib.v ..\rtl\neuroedge_top.v

echo === Compiling %TB% ===
call xvlog -i ..\rtl\params %RTL% ..\tb\%TB%.v
if errorlevel 1 exit /b 1
call xelab -debug typical %TB% -s %TB%_sim
if errorlevel 1 exit /b 1
echo === Simulating %TB% ===
call xsim %TB%_sim -R
endlocal
