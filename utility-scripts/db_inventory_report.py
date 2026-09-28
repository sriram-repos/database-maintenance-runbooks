"""
db_inventory_report.py

Purpose:
    Connect to a list of SQL Server / Azure SQL instances, 
    standardized inventory (database name, size, recovery model, last
    backup dates, compatibility level), and export a consolidated
    report to CSV and Excel. Can use it for environment audits, migration
    planning, or a recurring health-check pipeline.

Author:       Sriram Krishnamurthy
Last tested:  Sept 2026
Requires:
    pip install pyodbc pandas openpyxl

Usage:
    python db_inventory_report.py --config instances.json --output inventory_report

Config file format (instances.json):
    [
        {"server": "server1.database.windows.net", "database": "master",
         "auth": "sql", "username": "readonly_user", "password_env": "SQL_PW_1"},
        {"server": "SERVER2\\\\SQL2022", "database": "master", "auth": "windows"}
    ]

"""

import argparse # Handles command-line argument parsing (--config, --output)
import datetime
import json
import os
import sys

import pandas as pd
import pyodbc  # ODBC database driver interface used to connect to SQL Server / Azure SQL


# T-SQL Query to collect database metadata from SQL Server system views (sys.databases, sys.master_files, msdb)
INVENTORY_QUERY = """
SELECT
    d.name                          AS database_name,
    d.recovery_model_desc           AS recovery_model,
    d.state_desc                    AS state,
    d.compatibility_level,
    d.is_read_only,
    CAST(SUM(mf.size) * 8.0 / 1024 AS DECIMAL(12,2)) AS size_mb,
    (SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset
        WHERE database_name = d.name AND type = 'D')  AS last_full_backup,
    (SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset
        WHERE database_name = d.name AND type = 'L')  AS last_log_backup
FROM sys.databases d
JOIN sys.master_files mf ON d.database_id = mf.database_id
WHERE d.database_id > 4
GROUP BY d.name, d.recovery_model_desc, d.state_desc,
         d.compatibility_level, d.is_read_only
ORDER BY size_mb DESC;
"""

#Generate ODBC connection string. Windows Authentication and SQL Server Authentication
def build_connection_string(instance: dict) -> str:
    driver = "{ODBC Driver 18 for SQL Server}"
    server = instance["server"]
    database = instance.get("database", "master")

    if instance.get("auth") == "windows":
        return (
            f"DRIVER={driver};SERVER={server};DATABASE={database};"
            f"Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=no;"
        )

    username = instance["username"]
    password = os.environ.get(instance["password_env"], "")
    if not password:
        raise ValueError(
            f"Password env var '{instance['password_env']}' not set for {server}"
        )

    return (
        f"DRIVER={driver};SERVER={server};DATABASE={database};"
        f"UID={username};PWD={password};Encrypt=yes;TrustServerCertificate=no;"
    )

#Connects to a SQL Server instance, execute the inventory query, store result into a Pandas DataFrame.
def fetch_inventory(instance: dict) -> pd.DataFrame:
    conn_str = build_connection_string(instance)
    with pyodbc.connect(conn_str, timeout=10) as conn:
        df = pd.read_sql(INVENTORY_QUERY, conn)
    # Metadata columns into the DataFrame to identify instance and time run
    df.insert(0, "source_instance", instance["server"])
    df.insert(1, "collected_at_utc", datetime.datetime.utcnow())
    return df

#parse arguments, iterate through instances,aggregate inventory data and export reports.
def main():
    parser = argparse.ArgumentParser(description="Multi-instance SQL DB inventory report.")
    parser.add_argument("--config", required=True, help="Path to JSON config listing instances.")
    parser.add_argument("--output", default="inventory_report", help="Output file basename (no extension).")
    args = parser.parse_args()

    with open(args.config, "r") as f:
        instances = json.load(f)

    all_frames = []
    for instance in instances:
        server = instance.get("server", "UNKNOWN")
        try:
            print(f"Collecting inventory from {server} ...")
            df = fetch_inventory(instance)
            all_frames.append(df)
            print(f"  {len(df)} databases found.")
        except Exception as exc:
            print(f"  ERROR collecting from {server}: {exc}", file=sys.stderr)

    if not all_frames:
        print("No data collected from any instance. Exiting.", file=sys.stderr)
        sys.exit(1)

    combined = pd.concat(all_frames, ignore_index=True)

    csv_path = f"{args.output}.csv"
    xlsx_path = f"{args.output}.xlsx"
    combined.to_csv(csv_path, index=False)
    combined.to_excel(xlsx_path, index=False)

    print(f"\nReport written to:\n  {csv_path}\n  {xlsx_path}")
    print(f"Total databases across all instances: {len(combined)}")


if __name__ == "__main__":
    main()
