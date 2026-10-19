@echo off
REM Optional: run a testbench with Icarus Verilog instead of Vivado.
REM   run_icarus.bat tb_iir
setlocal
set TB=%1
if "%TB%"=="" set TB=tb_top
cd /d "%~dp0"
iverilog -g2005 -I ..\rtl\params -o %TB%.vvp ..\rtl\iir_bandpass.v ..\rtl\event_encoder.v ..\rtl\event_cov.v ..\rtl\drift_monitor.v ..\rtl\backend.v ..\rtl\ns_calib.v ..\rtl\neuroedge_top.v ..\tb\%TB%.v
if errorlevel 1 exit /b 1
vvp %TB%.vvp
endlocal
