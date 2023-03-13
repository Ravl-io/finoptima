param(
    [Parameter(Mandatory = $false)]
    [string] $TargetSubscription = $null,

    [Parameter(Mandatory = $false)]
    [string] $externalCloudEnvironment = "",

    [Parameter(Mandatory = $false)]
    [string] $externalTenantId = "",

    [Parameter(Mandatory = $false)]
    [string] $externalCredentialName = ""
)

$ErrorActionPreference = "Stop"

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$referenceRegion = Get-AutomationVariable -Name "AzureOptimization_ReferenceRegion" -ErrorAction SilentlyContinue # e.g., westeurope
if ([string]::IsNullOrEmpty($referenceRegion))
{
    $referenceRegion = "westeurope"
}
$authenticationOption = Get-AutomationVariable -Name  "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "ManagedIdentity"
}

# get ARG exports sink (storage account) details
$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_ARGPublicIpContainer" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($storageAccountSinkContainer))
{
    $storageAccountSinkContainer = "argpublicipexports"
}

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    $externalCredential = Get-AutomationPSCredential -Name $externalCredentialName
}

$ARGPageSize = 1000

Write-Output "Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "RunAsAccount" { 
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
    "ManagedIdentity" { 
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}

Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

$cloudSuffix = ""

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    Connect-AzAccount -ServicePrincipal -EnvironmentName $externalCloudEnvironment -Tenant $externalTenantId -Credential $externalCredential 
    $cloudSuffix = $externalCloudEnvironment.ToLower() + "-"
    $cloudEnvironment = $externalCloudEnvironment   
}

$tenantId = (Get-AzContext).Tenant.Id

$allpips = @()

Write-Output "Getting subscriptions target $TargetSubscription"
if (-not([string]::IsNullOrEmpty($TargetSubscription)))
{
    $subscriptions = $TargetSubscription
    $subscriptionSuffix = $TargetSubscription
}
else
{
    $AllowUnsupportedSubscriptions = [bool] (Get-AutomationVariable -Name  "AzureOptimization_AllowUnsupportedSubscriptions" -ErrorAction SilentlyContinue)
    if (-not($AllowUnsupportedSubscriptions))
    {
        $supportedQuotaIDs = @('EnterpriseAgreement_2014-09-01','PayAsYouGo_2014-09-01','MSDN_2014-09-01','MSDNDevTest_2014-09-01')
        $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" -and $_.SubscriptionPolicies.QuotaId -in $supportedQuotaIDs } | ForEach-Object { "$($_.Id)"}
    }
    else
    {
        Write-Output "Allowing unsupported subscriptions"
        $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } | ForEach-Object { "$($_.Id)"}
    }
    $subscriptionSuffix = $cloudSuffix + "all-" + $tenantId
}

$pipsTotal = @()

$resultsSoFar = 0

Write-Output "Querying for ARM Public IP properties"

$argQuery = @"
resources
| where type =~ 'microsoft.network/publicipaddresses'
| extend skuName = tolower(sku.name)
| extend skuTier = tolower(sku.tier)
| extend allocationMethod = tolower(properties.publicIPAllocationMethod)
| extend addressVersion = tolower(properties.publicIPAddressVersion)
| extend associatedResourceId = iif(isnotempty(properties.ipConfiguration.id),tolower(properties.ipConfiguration.id),tolower(properties.natGateway.id))
| extend ipAddress = tostring(properties.ipAddress)
| extend fqdn = tolower(properties.dnsSettings.fqdn)
| extend publicIpPrefixId = tostring(properties.publicIPPrefix.id)
| order by id asc
"@

do
{
    if ($resultsSoFar -eq 0)
    {
        $pips = Search-AzGraph -Query $argQuery -First $ARGPageSize -Subscription $subscriptions
    }
    else
    {
        $pips = Search-AzGraph -Query $argQuery -First $ARGPageSize -Skip $resultsSoFar -Subscription $subscriptions
    }
    if ($pips -and $pips.GetType().Name -eq "PSResourceGraphResponse")
    {
        $pips = $pips.Data
    }
    $resultsCount = $pips.Count
    $resultsSoFar += $resultsCount
    $pipsTotal += $pips

} while ($resultsCount -eq $ARGPageSize)

$datetime = (Get-Date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")
$statusDate = $datetime.ToString("yyyy-MM-dd")

Write-Output "Building $($pipsTotal.Count) ARM Public IP entries"

foreach ($pip in $pipsTotal)
{
    $logentry = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $cloudEnvironment
        TenantGuid = $pip.tenantId
        SubscriptionGuid = $pip.subscriptionId
        ResourceGroupName = $pip.resourceGroup.ToLower()
        Location = $pip.location
        Name = $pip.name.ToLower()
        InstanceId = $pip.id.ToLower()
        Model = "ARM"
        SkuName = $pip.skuName
        SkuTier = $pip.skuTier
        AllocationMethod = $pip.allocationMethod
        AddressVersion = $pip.addressVersion
        AssociatedResourceId = $pip.associatedResourceId
        PublicIpPrefixId = $pip.publicIpPrefixId
        IPAddress = $pip.ipAddress
        FQDN = $pip.fqdn
        Zones = $pip.zones
        Tags = $pip.tags
        StatusDate = $statusDate
    }
    
    $allpips += $logentry
}

$pipsTotal = @()

$resultsSoFar = 0

Write-Output "Querying for Classic Reserved IP properties"

$argQuery = @"
resources
| where type =~ 'microsoft.classicnetwork/reservedips'
| extend ipAddress = tostring(properties.ipAddress)
| extend allocationMethod = 'static'
| extend addressVersion = 'ipv4'
| extend associatedResourceId = tolower(properties.attachedTo.id)
| extend ipAddress = tostring(properties.ipAddress)
| order by id asc
"@

do
{
    if ($resultsSoFar -eq 0)
    {
        $pips = Search-AzGraph -Query $argQuery -First $ARGPageSize -Subscription $subscriptions
    }
    else
    {
        $pips = Search-AzGraph -Query $argQuery -First $ARGPageSize -Skip $resultsSoFar -Subscription $subscriptions
    }
    if ($pips -and $pips.GetType().Name -eq "PSResourceGraphResponse")
    {
        $pips = $pips.Data
    }
    $resultsCount = $pips.Count
    $resultsSoFar += $resultsCount
    $pipsTotal += $pips

} while ($resultsCount -eq $ARGPageSize)

$datetime = (Get-Date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")
$statusDate = $datetime.ToString("yyyy-MM-dd")

Write-Output "Building $($pipsTotal.Count) Classic Reserved IP entries"

foreach ($pip in $pipsTotal)
{
    $logentry = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $cloudEnvironment
        TenantGuid = $pip.tenantId
        SubscriptionGuid = $pip.subscriptionId
        ResourceGroupName = $pip.resourceGroup.ToLower()
        Location = $pip.location
        Name = $pip.name.ToLower()
        InstanceId = $pip.id.ToLower()
        Model = "Classic"
        AllocationMethod = $pip.allocationMethod
        AddressVersion = $pip.addressVersion
        AssociatedResourceId = $pip.associatedResourceId
        IPAddress = $pip.ipAddress
        StatusDate = $statusDate
    }
    
    $allpips += $logentry
}

Write-Output "Uploading CSV to Storage"

$today = $datetime.ToString("yyyyMMdd")
$csvExportPath = "$today-publicips-$subscriptionSuffix.csv"

$allpips | Export-Csv -Path $csvExportPath -NoTypeInformation

$csvBlobName = $csvExportPath

$csvProperties = @{"ContentType" = "text/csv"};

Set-AzStorageBlobContent -File $csvExportPath -Container $storageAccountSinkContainer -Properties $csvProperties -Blob $csvBlobName -Context $sa.Context -Force

$now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
Write-Output "[$now] Uploaded $csvBlobName to Blob Storage..."

Remove-Item -Path $csvExportPath -Force

$now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
Write-Output "[$now] Removed $csvExportPath from local disk..."    