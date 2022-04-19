Useful Azure Automation Runbooks to maintain Azure services

* Backup SQL Database to blob storage (to support offsite backups)

     Supports connections over Private Link with recently added functionality (https://techcommunity.microsoft.com/t5/azure-sql-blog/import-export-using-private-link-now-in-preview/ba-p/3256192)

If running in Azure automation account
* Update Powershell modules to latest version before running scripts

See more information from https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Update-ModulesInAutomationToLatestVersion.ps1
See more information about Azure Automation: https://docs.microsoft.com/en-us/azure/automation/

If running locally
* Remove login part from the script
* Run Login-AzAccount or Connect-AzAccount to login you Azure subscription if script is using AzureRunAsConnection

You need Azure Powershell cmdlets when running scripts locally. See more information from https://docs.microsoft.com/en-us/powershell/azureps-cmdlets-docs/