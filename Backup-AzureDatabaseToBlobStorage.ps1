<#
.SYNOPSIS
	This Azure Automation runbook automates Azure SQL database backup to Blob storage and deletes old backups from blob storage.

.DESCRIPTION
	You should use this Runbook if you want manage Azure SQL database backups in Blob storage.
	This runbook can be used together with Azure SQL Point-In-Time-Restore. Now supports Private Link - endpoints.

	This is a PowerShell runbook, as opposed to a PowerShell Workflow runbook.
    This is an updated version of the original script found here: https://github.com/jlaari/PowerShell-Runbooks , https://github.com/azureautomation/backup-azure-sql-databases-to-blob-storage

.PARAMETER SubscriptionId
	Subscription ID of the Azure SQL server

.PARAMETER ResourceGroupName
	Specifies the name of the resource group where the Azure SQL Database server is located

.PARAMETER saResourceId
	Specifies the full resource ID for the storage account
	
.PARAMETER sqlServerName
	Specifies the name of the Azure SQL Database Server which script will backup
	
.PARAMETER aaCrSqlName
	Name of the stored credential of an administrative user for the SQL server

.PARAMETER DatabaseNames
	Comma separated list of databases script will backup
	
.PARAMETER StorageAccountName
	Specifies the name of the storage account where backup file will be uploaded

.PARAMETER BlobStorageEndpoint
	Specifies the base URL of the storage account
	
.PARAMETER aaCrStorageKeyName
	Name of the stored credential for the storage account access key

.PARAMETER BlobContainerName
	Specifies the container name of the storage account where backup file will be uploaded. Container will be created if it does not exist.

.PARAMETER RetentionDays
	Specifies the number of days how long backups are kept in blob storage. Script will remove all older files from container. 
	For this reason dedicated container should be only used for this script.

.PARAMETER PrivateLink
    Boolean specifying use of Private Link connections to either resource.

.INPUTS
	None.

.OUTPUTS
	Human-readable informational and error messages produced during the job. Not intended to be consumed by another runbook.

#>

param(
	[parameter(Mandatory=$true)]
	[string]$SubscriptionId,
    [parameter(Mandatory=$true)]
	[string]$ResourceGroupName,
    [parameter(Mandatory=$true)]
	[string]$saResourceId,
    [parameter(Mandatory=$true)]
	[string]$sqlServerName,
    [parameter(Mandatory=$true)]
	[string]$aaCrSqlName,
	[parameter(Mandatory=$true)]
    [string]$DatabaseNames,
    [parameter(Mandatory=$true)]
    [string]$StorageAccountName,
    [parameter(Mandatory=$true)]
    [string]$BlobStorageEndpoint,
    [parameter(Mandatory=$true)]
    [string]$aaCrStorageKeyName,
	[parameter(Mandatory=$true)]
    [string]$BlobContainerName,
	[parameter(Mandatory=$true)]
    [Int32]$RetentionDays,
    [parameter(Mandatory=$true)]
    [Boolean]$PrivateLink
)

$ErrorActionPreference = 'stop'

# Requirement to retrieve PSCredential objects
Import-Module Orchestrator.AssetManagement.Cmdlets -ErrorAction SilentlyContinue

function Login() {
	$connectionName = "AzureRunAsConnection"
	try
	{
		$servicePrincipalConnection = Get-AutomationConnection -Name $connectionName         

		Write-Verbose "Logging in to Azure..." -Verbose

		Add-AzAccount `
			-ServicePrincipal `
			-TenantId $servicePrincipalConnection.TenantId `
			-ApplicationId $servicePrincipalConnection.ApplicationId `
			-CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint | Out-Null

		Set-AzContext -SubscriptionId $SubscriptionId
	}
	catch {
		if (!$servicePrincipalConnection)
		{
			$ErrorMessage = "Connection $connectionName not found."
			throw $ErrorMessage
		} else{
			Write-Error -Message $_.Exception
			throw $_.Exception
		}
	}
}

function New-Blob-Container([string]$blobContainerName, $storageContext) {
	Write-Verbose "Checking if blob container '$blobContainerName' already exists" -Verbose
	if (Get-AzStorageContainer -ErrorAction "Stop" -Context $storageContext | Where-Object { $_.Name -eq $blobContainerName }) {
		Write-Verbose "Container '$blobContainerName' already exists" -Verbose
	} else {
		New-AzStorageContainer -ErrorAction "Stop" -Name $blobContainerName -Permission Off -Context $storageContext
		Write-Verbose "Container '$blobContainerName' created" -Verbose
	}
}

function Export-To-Blob-Storage([string]$ResourceGroupName, [string]$sqlServerName, [string]$aaCrSqlName, [string[]]$databaseNames, [string]$blobStorageEndpoint, [string]$blobContainerName, [string]$saResourceId, [Boolean]$PrivateLink) {
	Write-Verbose "Starting database export of databases '$databaseNames'" -Verbose
	$sqlCred = Get-AutomationPSCredential -Name $aaCrSqlName

	foreach ($databaseName in $databaseNames.Split(",").Trim()) {
		
		$bacpacFilename = $databaseName + (Get-Date).ToString("yyyyMMddHHmm") + ".bacpac"
		$bacpacUri = $blobStorageEndpoint + $blobContainerName + "/" + $bacpacFilename

		if ($PrivateLink) {
			Write-Verbose "Getting SQL server resource details"
			$sqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $sqlServerName
			
			Write-Verbose "Creating request to backup database '$databaseName' (over Private Link)"
			$exportRequest = New-AzSqlDatabaseExport `
				-ResourceGroupName $ResourceGroupName `
				-ServerName $sqlServerName `
				-DatabaseName $databaseName `
				-StorageKeytype "StorageAccessKey" `
				-storageKey $storageKey.GetNetworkCredential().Password `
				-StorageUri $BacpacUri `
				-AdministratorLogin $sqlCred.UserName `
				-AdministratorLoginPassword $sqlCred.Password `
				-UseNetworkIsolation $PrivateLink `
				-StorageAccountResourceIdForPrivateLink $saResourceId `
				-SqlServerResourceIdForPrivateLink $sqlServer.ResourceId `
				-ErrorAction "Stop"

			Start-Sleep -Seconds 30

			## Approve the Private Endpoint Connection for the Storage Account
			$saPrivateEndpoint = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $saResourceId | `
				Where-Object {($_.PrivateEndpoint.Id -like "*ImportExportPrivateLink_Storage*" -and $_.PrivateLinkServiceConnectionState.status -eq "Pending")}
			Approve-AzPrivateEndpointConnection -ResourceId $saPrivateEndpoint.Id

			## Approve the Private Endpoint Connection for the SQL Account
			$sqlPrivateEndpoint = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $sqlServer.ResourceId | `
				Where-Object {($_.PrivateEndpoint.Id -like "*ImportExportPrivateLink_SQL*" -and $_.PrivateLinkServiceConnectionState.status -eq "Pending")}
			Approve-AzPrivateEndpointConnection -ResourceId $sqlPrivateEndpoint.Id

			Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $exportRequest.OperationStatusLink | Where-Object {($_.Status -eq "InProgress")}
		} else {
			Write-Verbose "Creating request to backup database '$databaseName'"
			$exportRequest = New-AzSqlDatabaseExport -ResourceGroupName $ResourceGroupName -ServerName $sqlServerName `
			-DatabaseName $databaseName -StorageKeytype "StorageAccessKey" -storageKey $storageKey.GetNetworkCredential().Password -StorageUri $BacpacUri `
			-AdministratorLogin $sqlCred.UserName -AdministratorLoginPassword $sqlCred.Password -ErrorAction "Stop"

			Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $exportRequest.OperationStatusLink -ErrorAction "Stop"
		}
	}
}

function Remove-Old-Backups([int]$retentionDays, [string]$blobContainerName, $storageContext) {
	Write-Output "Removing backups older than '$retentionDays' days from blob: '$blobContainerName'"
	$isOldDate = [DateTime]::UtcNow.AddDays(-$retentionDays)
	$blobs = Get-AzStorageBlob -Container $blobContainerName -Context $storageContext
	foreach ($blob in ($blobs | Where-Object { $_.LastModified.UtcDateTime -lt $isOldDate -and $_.BlobType -eq "BlockBlob" })) {
		Write-Verbose ("Removing blob: " + $blob.Name) -Verbose
		Remove-AzStorageBlob $blob.Name -Container $blobContainerName -Context $storageContext
	}
}

Write-Verbose "Starting database backup" -Verbose

$storageKey = Get-AutomationPSCredential -Name $aaCrStorageKeyName
$StorageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageKey.GetNetworkCredential().Password

Login

New-Blob-Container `
	-blobContainerName $blobContainerName `
	-storageContext $storageContext
	
Export-To-Blob-Storage `
	-resourceGroupName $ResourceGroupName `
	-sqlServerName $sqlServerName `
	-aaCrSqlName $aaCrSqlName `
	-databaseNames $DatabaseNames `
	-blobStorageEndpoint $BlobStorageEndpoint `
	-blobContainerName $BlobContainerName `
	-saResourceId $saResourceId `
	-PrivateLink $PrivateLink
	
Remove-Old-Backups `
	-retentionDays $RetentionDays `
	-storageContext $StorageContext `
	-blobContainerName $BlobContainerName
	
Write-Verbose "Database backup script finished" -Verbose
