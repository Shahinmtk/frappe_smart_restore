# frappe_smart_restore
The frappe_smart_restore script is an automated, production-ready tool designed to safely restore Frappe/ERPNext backups while preventing database migration failures caused by missing custom applications.


Automatic Detection: It automatically locates the active Frappe bench directory, selects the target site, and identifies the latest matching database, public, and private file backups.

Pre-Restore Inspection: Before altering any data, the script scans the SQL backup file to identify applications that are registered in the backup but missing from the current server environment.

Dummy App Recovery: If missing apps are found, the script generates temporary "dummy apps" to satisfy Frappe's Python module import checks, allowing the initial database migration to pass without crashing.

Safe Registry Cleanup: Following the first migration, the script safely unlinks the missing applications using remove-from-installed-apps. This clears the app from the registry while preserving its underlying SQL data tables, unlike the destructive uninstall-app command which permanently deletes data.

End-to-End Automation: The workflow automatically handles pre-restore safety backups, full data restoration, two-stage migrations, and the final cleanup of the temporary dummy apps.
