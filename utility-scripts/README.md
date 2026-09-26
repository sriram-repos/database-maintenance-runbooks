# database-utility-scripts

PowerShell and Python automation for tasks around the database maintenance
such as log extraction, monitoring, and multi-instance reporting.

| Script | Language | Purpose |
|---|---|---|
| `extract_sql_error_logs.ps1` | PowerShell | Pulls SQL Server error log entries above a severity threshold across multiple instances, exports to CSV |
| `db_inventory_report.py` | Python | Connects to a list of instances, builds a consolidated inventory (size, recovery model, last backup dates), exports CSV + Excel |

## Requirements
- PowerShell: `Install-Module -Name SqlServer -Scope CurrentUser`
- Python: `pip install pyodbc pandas openpyxl`

## Design notes
- Do not hardcode credentials — the Python script reads passwords from
  environment variables named in a config file; the PowerShell script
  assumes integrated auth or can use a credential store.
- Both scripts are read-only against the target instances.
- Designed to be dropped into a scheduled task, SQL Agent job step, or
  Azure Automation runbook.
