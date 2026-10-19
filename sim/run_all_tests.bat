@echo off
REM Runs all five testbenches in Vivado's simulator and prints the PASS/FAIL lines.
REM Full logs are in sim\log_<testbench>.txt
cd /d "%~dp0"
for %%T in (tb_iir tb_encoder tb_event_cov tb_ns tb_top) do (
    echo.
    echo ##### %%T #####
    call run_xsim.bat %%T > log_%%T.txt 2>&1
    findstr /B /C:"PASS" /C:"FAIL" /C:"ERROR" log_%%T.txt
)
echo.
echo Done. Every line above should start with PASS.
