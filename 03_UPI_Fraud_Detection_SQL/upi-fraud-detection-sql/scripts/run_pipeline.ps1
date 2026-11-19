# -----------------------------------------------------------------------------
# One-command end-to-end run for Windows PowerShell.
#
#   .\scripts\run_pipeline.ps1            # full dataset
#   .\scripts\run_pipeline.ps1 -Small     # quick demo dataset
#   .\scripts\run_pipeline.ps1 -RulesOnly # re-run rules on already-loaded data
#
# Needs psql on PATH (it ships with PostgreSQL, e.g. C:\Program Files\PostgreSQL\16\bin).
# Set $env:PGPASSWORD first if your postgres user has a password.
# -----------------------------------------------------------------------------
param([switch]$Small, [switch]$RulesOnly)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

if (-not $env:PGHOST)     { $env:PGHOST = "localhost" }
if (-not $env:PGPORT)     { $env:PGPORT = "5432" }
if (-not $env:PGUSER)     { $env:PGUSER = "postgres" }
if (-not $env:PGDATABASE) { $env:PGDATABASE = "upi_fraud" }

Write-Host ">> target database: $($env:PGUSER)@$($env:PGHOST):$($env:PGPORT)/$($env:PGDATABASE)"

$exists = psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$($env:PGDATABASE)'"
if ($exists -ne "1") {
    Write-Host ">> creating database $($env:PGDATABASE)"
    psql -d postgres -c "CREATE DATABASE $($env:PGDATABASE)"
}

New-Item -ItemType Directory -Force -Path "dashboard\data" | Out-Null

if ($RulesOnly) {
    psql -q -v skip_load=1 -f sql/run_all.sql
} elseif ($Small) {
    python data_generator/generate_data.py --accounts 10000 --txns 120000
    psql -q -f sql/run_all.sql
} else {
    python data_generator/generate_data.py
    psql -q -f sql/run_all.sql
}
if ($LASTEXITCODE -ne 0) { throw "pipeline failed" }
