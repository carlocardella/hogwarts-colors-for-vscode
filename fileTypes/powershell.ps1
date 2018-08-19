
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidateScript( {Test-Path $_})]
    [Alias('Fullname', 'Filename')]
    [string[]]$ServiceXml,

    [parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputFolder,

    [parameter()]
    [string]$TemplateRegion, 

    [parameter()]
    [string]$NewRegion,

    [parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [ValidateScript( { [guid]::Parse($_) })]
    [string]$SubscriptionId,

    [parameter()]
    [switch]$Force, 

    [parameter()]
    [switch]$Service,
    
    [parameter()]
    [switch]$StorageAccount,
    
    [parameter()]
    [switch]$TrafficManager,

    [parameter()]
    [switch]$SqlServer,

    [parameter()]
    [switch]$Certificate
)

begin {
    Import-Module LSEOaaS -Verbose:$false | Out-Null
    Import-Module LSEAzure -Verbose:$false | Out-Null
    Import-Module LSEOaaSDeploy -Verbose:$false | Out-Null
    Import-Module LSEFunctions -Verbose:$false | Out-Null

    $TemplateRegion = ConvertTo-PascalCase -String $TemplateRegion

    $templateLocation = Get-OaaSAzureLocation | Where-Object ShortName -EQ $TemplateRegion
    $newLocation = Get-OaaSAzureLocation | Where-Object ShortName -EQ $NewRegion

    [bool]$updateServiceXml = $false
}

process {
    foreach ($sxml in $ServiceXml) {
        Write-Verbose -Message "$sxml"
        # create the new service xml
        $destinationSXml = (Split-Path -Path $sxml -Leaf) -replace $TemplateRegion, $NewRegion
        $newServiceXml = Join-Path -Path $OutputFolder -ChildPath $destinationSXml
        Copy-Item -Path $sxml -Destination $newServiceXml -Force:$Force -ErrorAction Inquire
        Set-ItemProperty -Path $newServiceXml -Name 'IsReadOnly' -Value $false -ErrorAction Inquire -Force
        
        # update the region acronym
        Write-Verbose -Message "Updating Region acronym"
        Update-StringInFile -FilePath $newServiceXml -OldString $TemplateRegion.ToLower() -NewString $NewRegion.ToLower() -MatchCase -Force:$Force
        Update-StringInFile -FilePath $newServiceXml -OldString $TemplateRegion.ToUpper() -NewString $NewRegion.ToUpper() -MatchCase -Force:$Force
        Update-StringInFile -FilePath $newServiceXml -OldString (ConvertTo-PascalCase -String $TemplateRegion) -NewString (ConvertTo-PascalCase -String $NewRegion) -MatchCase -Force:$Force

        # update resource locatoins
        Write-Verbose -Message "Updating location name"
        Update-StringInFile -FilePath $newServiceXml -OldString $templateLocation.ExtendedName -NewString $newLocation.ExtendedName -MatchCase -Force:$Force
        
        # open the service xml and replate some known values with string placeholders
        $serviceXmlFile = $null
        [xml]$serviceXmlFile = Get-Content -Path $newServiceXml -ErrorAction Inquire
        $serviceID = $null
        $microservice = $null
        $serviceID = $serviceXmlFile.Service.ID
        [bool]$dsc = $false
        switch ($serviceID) {
            { $_ -match 'OaaSAgentSvc' } { $microservice = 'DSC'; $dsc = $true }
            { $_ -match 'OaaSProdPortal' } { $microservice = 'Portal' }
            { $_ -match 'OaasContainerService' } { $microservice = 'Container' }
            { $_ -match 'OaaSJobRuntimeData' } { $microservice = 'JRDS' }
            { $_ -match 'OaaSJobService' } { $microservice = 'JobService' }
            { $_ -match 'OaaSTriggerService' } { $microservice = 'Trigger' }
            { $_ -match 'OaaSWebhook' } { $microservice = 'Webhooks' }
            { $_ -match 'OaaSWeb' } { $microservice = 'WebService' }
            Default {}
        }

        $stashClient = Join-Path -Path $OutputFolder -ChildPath 'stashclient.txt'
        
        # update the subscription id
        Write-Verbose -Message "Updating Subscription Id"
        $serviceXmlFile.Service.Resources.AzureSubscriptions.AzureSubscription.SubscriptionId = $SubscriptionId

        # connect to Azure to begin the provisioning
        Connect-AzureAccountInteractive | Out-Null
        Select-OaaSSubscription -Geo $NewRegion.ToUpper() -DSC:$dsc





        #############################################################
        # STORAGE ACCOUNTS  
        if ($StorageAccount) {
            $storageAccounts = $serviceXmlFile.Service.Resources.AzureSubscriptions.AzureSubscription.AzureStorageAccounts.AzureStorageAccount
            foreach ($sa in $storageAccounts) {
                # this is really a Redis Cache
                if ($sa.Name -contains 'redis') {
                    $redisCacheRG = New-AzureRmResourceGroup -Name $sa.Name -Location $newLocation.ExtendedName
                    New-OaaSRedisCache -RedisCacheName $sa.Name -Location $newLocation.ExtendedName -ResourceGroupName $redisCacheRG.Name
                    $redisCacheKey = Get-AzureRmRedisCacheKey -ResourceGroupName $redisCacheRG -Name $sa.Name
                    $secretName = $null
                    $secretName = Get-SecretPathFromServiceXmlKeyword -Keyword $sa.Key
                    .\Push-OaaSSecretToProdStore.ps1 -SecretType StorageAccount -SecretName $secretName -Account $saKeys.StorageAccountName -Key1 $redisCacheRG.PrimaryKey -Key2 $redisCacheKey.SecondaryKey -KeyVault -SecretStore -InformationAction Continue
                    
                    continue
                }
           
                # cosmos
                if (($sa.Name -contains 'cosmos') -or ($sa.Name -contains 'sb')) {
                    New-AzureRmResourceGroup -Name $sa.Name -Location $newLocation.ExtendedName | Out-Null
                    ## NOTE: is this valid?!?
                    # New-AzureRmEventHub -NamespaceName $sa.Name -ResourceGroupName $sa.Name -Location $newLocation.ExtendedName -EventHubName $sa.Name
                    $eventHub = $null
                    $eventHub = New-AzureSBNamespace -Name $sa.Name -Location $newLocation.ExtendedName -CreateACSNamespace:$false -NamespaceType EventHub
                    $eventHubKey = Get-AzureSBAuthorizationRule -Namespace $sa.Name
                }

                # service bus
                if (($sa.Name -contains 'servicebus') -or ($sa.Name -contains 'sb')) {
                    $sbNamespace = New-OaaSServiceBusNamespace -NamespaceName $sa.Name -Location $newLocation.ExtendedName
                    $secretName = $null
                    $secretName = Get-SecretPathFromServiceXmlKeyword -Keyword $sa.Key
                    ## TODO: is DefaultKey used for all Service Bus secrets? 
                    .\Push-OaaSSecretToProdStore.ps1 -SecretType StorageAccount -SecretName $secretName -Account $sbNamespace.Name -Key1 $sbNamespace.DefaultKey -KeyVault -SecretStore -InformationAction Continue
                    
                    continue
                }

                # to be skipped
                if ($sa.Name -eq 'NcusCaasServicePassword') {
                    continue
                }

                # create keys with Mike's tool
                if ($sa.Name -match 'HmacSignature') {
                    # ScriptHost.HmacSignature.EncodedPrimarySecret
                    $hmacSignaturePrimary = New-HmacSignatureSecret
                    $secretName = $null
                    $secretName = Get-SecretPathFromServiceXmlKeyword -Keyword $sa.Key
                    .\Push-OaaSSecretToProdStore.ps1 -SecretType StorageAccount -SecretName $secretName -Account 'ScriptHost.HmacSignature.EncodedPrimarySecret' -Key1 $hmacSignaturePrimary -KeyVault -SecretStore -InformationAction Continue
                    
                    # ScriptHost.HmacSignature.EncodedSecondarySecret
                    $hmacSignatureSecondary = New-HmacSignatureSecret
                    $secretName = $null
                    $secretName = Get-SecretPathFromServiceXmlKeyword -Keyword $sa.Key
                    .\Push-OaaSSecretToProdStore.ps1 -SecretType StorageAccount -SecretName $secretName -Account 'ScriptHost.HmacSignature.EncodedSecondarySecret' -Key1 $hmacSignatureSecondary -KeyVault -SecretStore -InformationAction Continue
                }

                # create the Storage Account
                New-OaaSStorageAccount -StorageAccountName $sa.Name -Location $newLocation.ExtendedName
                $saKeys = $null
                $saKeys = Get-AzureStorageKey -StorageAccountName $sa.Name
                $secretName = $null
                $secretName = Get-SecretPathFromServiceXmlKeyword -Keyword $sa.Key
                .\Push-OaaSSecretToProdStore.ps1 -SecretType StorageAccount -SecretName $secretName -Account $saKeys.StorageAccountName -Key1 $saKeys.Primary -Key2 $saKeys.Secondary -KeyVault -SecretStore -InformationAction Continue

            }
        }




        #############################################################
        # SQL DATABASES
        if ($SqlServer) {
            $sqlDatabases = $serviceXmlFile.Service.Resources.AzureSubscriptions.AzureSubscription.SqlAzureDatabases.SqlAzureDatabase
            if ($sqlDatabases.Count -gt 0) {
                # check for existing sql server replication
                $sqlServerReplicationDetails = $null
                $sqlServerReplicationDetails = Get-AzureSqlDatabaseReplicationDetail
                if ($sqlServerReplicationDetails.Cout -gt 0) {
                    Write-Information -MessageData "Existing Sql Server replication `n $($sqlServerReplicationDetails | Out-String)"
                    Write-Warning -Message "Please review existing Sql Server configuration for Subscription $((Get-AzureSubscription -Current).SubscriptionId)"
                    break
                }
            
                $sqlServers = $null
                $sqlServers = Get-AzureSqlDatabaseServer
                if ($sqlServers.Count -gt 0) {
                    Write-Information -MessageData "Sql Server already available `n $($sqlServers | Out-String)"
                    Write-Warning -Message "Please review existing Sql Server configuration for Subscription $((Get-AzureSubscription -Current).SubscriptionId)"
                    break
                }
            

                $database = $sqlDatabases.Where( {$_.ID -eq 'SqlDatabase'})
                $username = @($database.Username -split '@')[0]
                $password = $null
                $password = New-Password -Length 20 -NumberOfNonAlphanumericCharacters 5
                
                if ($dsc) {
                    New-OaaSSqlDatabase -AdministratorLogin $username -Password (ConvertTo-SecureString -AsPlainText -Force $password) -DatabaseName $database -Location $newLocation.ExtendedName -LocationDR $newLocation.DR -ServiceObjective P2 -CreateSecondaryDR

                    ## TODO: create sql low priviledge accounts
                }
                else {
                    New-OaaSSqlDatabase -AdministratorLogin $username -Password (ConvertTo-SecureString -AsPlainText -Force $password) -DatabaseName $database -Location $newLocation.ExtendedName -LocationDR $newLocation.DR -ServiceObjective P2 -CreateSecondaryDR -CreateSecondary

                    # create sql accounts
                    Write-Verbose -Message "Creating logins on $($sqlServerReplicationDetails.SourceServerName)"
                    Write-Verbose "ROViewsMaster on master"
                    $password = New-Password -Length 20 -NumberOfNonAlphanumericCharacters 5
                    Set-OaaSSqlQuery -Geo $NewRegion -DSC:$dsc -SqlCommand "CREATE LOGIN ROViewsMaster WITH password='$password'"
                    .\Push-OaaSSecretToProdStore.ps1 -SecretStore -KeyVault -SecretType Password -SecretName "CDM/OAAS/OaaSProd$($NewRegion)s1/Sql/ROViewsMaster" -Password "Server=tcp:$($sqlServerReplicationDetails.SourceServerName).database.windows.net,1433;Database=master;User ID=ROViewsMaster@$($sqlServerReplicationDetails.SourceServerName);Password=$password;Trusted_Connection=False;Encrypt=True;"
                
                    Write-Verbose -Message "ROViewsSQL on master"
                    $password = New-Password -Length 20 -NumberOfNonAlphanumericCharacters 5
                    Set-OaaSSqlQuery -Geo $NewRegion -DSC:$dsc -SqlCommand "CREATE LOGIN ROViewsSQL WITH password='$password'"
                    .\Push-OaaSSecretToProdStore.ps1 -SecretStore -KeyVault -SecretType Password -SecretName "CDM/OAAS/OaaSProd$($NewRegion)s1/Sql/ROViewsSQL" -Password "Server=tcp:$($sqlServerReplicationDetails.SourceServerName).database.windows.net,1433;Database=$($sqlServerReplicationDetails.SourceDatabaseName);User ID=ROViewsSQL@$($sqlServerReplicationDetails.SourceServerName);Password=$password;Trusted_Connection=False;Encrypt=True;"
                
                    # grant permission
                    Write-Verbose -Message "Creating logins on $($sqlServerReplicationDetails.SourceServerName)"
                    Set-OaaSSqlQuery -Geo $NewRegion -DSC:$dsc -SqlCommand "CREATE USER ROViewsSQL FROM LOGIN ROViewsSQL"
                    Set-OaaSSqlQuery -Geo $NewRegion -DSC:$dsc "EXEC sp_addrolemember 'db_datareader', 'ROViewsSQL'"
                    Set-OaaSSqlQuery -Geo $NewRegion -DSC:$dsc "GRANT VIEW DATABASE STATE TO ROViewsSQL"
                }

                # validate Sql replication 
                $sqlServerReplicationDetails = $null
                $sqlServerReplicationDetails = Get-AzureSqlDatabaseReplicationDetail
                if ($dsc) {
                    if ($sqlServerReplicationDetails.Count -ne 1) {
                        Write-Error -Message "Error setting up Sql DR replication"
                    }
                    else {
                        # update the service xml
                        Write-Verbose -Message 'Updating Sql Server details in service xml'
                        
                        # sqlDatabase
                        # $sqlDatabases = $null
                        # $sqlDatabase = $sqlDatabases.Where( {$_.ID -eq 'SqlDatabase'})
                        # $sqlDatabase.Server = "$($sqlServerReplicationDetails.SourceServerName).database.windows.net"
                        # $sqlDatabase.Username = "$($username)@$($sqlServerReplicationDetails.SourceServerName)"
                        
                        # SecondarySqlDatabase
                        $secondarySqlDatabase = $null
                        $secondarySqlDatabase = $sqlDatabases.Where( {$_.ID -eq 'SecondarySqlDatabase'})
                        $secondarySqlDatabase.Server = "$($sqlServerReplicationDetails.DestinationServerName).database.windows.net"
                        $secondarySqlDatabase.Username = "$($username)@$($sqlServerReplicationDetails.DestinationServerName)"
                        
                        $updateServiceXml = $true
                    }
                }
                else {
                    if ($sqlServerReplicationDetails.Cloud -ne 2) {
                        Write-Error -Message "Error setting up Sql DR replication"
                    }
                    else {
                        ## TODO:
                        # update the service xml
                        Write-Verbose -Message 'Updating Sql Server details in service xml'
                        
                        # # sqlDatabase
                        # $sqlDatabase = $null
                        # $sqlDatabase = $sqlDatabases.Where( {$_.ID -eq 'SqlDatabase'})
                        # $sqlDatabase.Server = "$($sqlServerReplicationDetails.SourceServerName).database.windows.net"
                        # $sqlDatabase.Username = "$($username)@$($sqlServerReplicationDetails.SourceServerName)"
                        
                        # SecondarySqlDatabase
                        $secondarySqlDatabase = $null
                        $secondarySqlDatabase = $sqlDatabases.Where( {$_.ID -eq 'SecondarySqlDatabase'})
                        $secondarySqlDatabase.Server = "$($sqlServerReplicationDetails.Where({$_.IsLocal -eq 'True'}).DestinationServerName).database.windows.net"
                        $secondarySqlDatabase.Username = "$($username)@$($sqlServerReplicationDetails.Where({$_.IsLocal -eq 'True'}).DestinationServerName)"
                        
                        # SecondarySqlDatabase
                        $secondaryDrSqlDatabase = $null
                        $secondaryDrSqlDatabase = $sqlDatabases.Where( {$_.ID -eq 'secondaryDrSqlDatabase'})
                        $secondaryDrSqlDatabase.Server = "$($sqlServerReplicationDetails.Where({$_.IsLocal -eq 'False'}).DestinationServerName).database.windows.net"
                        $secondaryDrSqlDatabase.Username = "$($username)@$($sqlServerReplicationDetails.Where({$_.IsLocal -eq 'True'}).DestinationServerName)"
                        
                        $updateServiceXml = $true
                    }
                }
                
                ## export account and password to secret store / keyvault
                if ($sqlServerReplicationDetails -ne $null) {
                    $secretName = $null
                    $secretName = Get-SecretPathFromServiceXmlKeyword -Keyword $($database.Password)
                    .\Push-OaaSSecretToProdStore.ps1 -KeyVault -SecretStore -SecretType Password -Password $password -SecretName $secretName -InformationAction Continue
                }
                else {
                    Write-Error -Message "Sql database replication error"
                }
                
                
                ## add sql vip
                $armSqlServers = Get-AzureRmSqlServer
                $sqlVipName = $null
                if ($dsc) {
                    $sqlVipName = "$($NewRegion.ToLower())gentservicesqlvip"
                }
                else {
                    $sqlVipName = "oaasdb$($NewRegion.ToLower())vip"
                }
                $primarySqlServer = $armSqlServers | Where-Object ServerName -eq $($sqlServerReplicationDetails.SourceServerName)
                $partnerSqlServer = $armSqlServers | Where-Object ServerName -eq $($sqlServerReplicationDetails.DestinationServerName) | Where-Object $sqlServerReplicationDetails.IsLocal -eq $false
                $primarySqlServer | New-AzureRmSqlServerDisasterRecoveryConfiguration -PartnerServerName $partnerSqlServer.ServerName -PartnerResourceGroupName $partnerSqlServer.ResourceGroupName -VirtualEndpointName $sqlVipName -FailoverPolicy "UserControlled"
                
                # sqlDatabase
                $sqlDatabase = $null
                $sqlDatabase = $sqlDatabases.Where( {$_.ID -eq 'SqlDatabase'})
                $sqlDatabase.Server = "$($sqlServerReplicationDetails.SourceServerName).database.windows.net"
                $sqlDatabase.Username = "$($username)@$($sqlServerReplicationDetails.SourceServerName)"

                $updateServiceXml = $true




                ## TODO: add firewall rules
                ## TODO: get the list of proxies/ip ranges to add
                # allow connections from Azure services
                Get-AzureSqlDatabaseServer | New-AzureSqlDatabaseServerFirewallRule -AllowAllAzureServices
                $msProxies | ForEach-Object {
                    New-AzureSqlDatabaseServerFirewallRule -ServerName $($sqlServerReplicationDetails.SourceServerName) -RuleName "ms_proxy_$((Get-Date).Ticks)" -StartIpAddress $_.StartIpAddress -EndIpAddress $_.EndIpAddress 
                }
            }
        }




        #############################################################
        # CLOUD SERVICES
        if ($Service) {
            New-OaaSService -Geo $newLocation.ShortName -Microservice $microservice -Location $newLocation.ExtendedName -LocationDR $newLocation.DR -InformationAction Continue
        }





        #############################################################
        # TRAFFIC MANAGER
        if ($TrafficManager) {
            # register the resource provider (some new subscriptions don't have it enabled by default)
            Register-AzureRmResourceProvider -ProviderNamespace 'Microsoft.Network' -ErrorAction SilentlyContinue

            # TM profles to create
            # wus2-oaas-prod-su1.azure-automation.net.	CNAME	wus2-oaaswebservice-prod-arm-1.trafficmanager.net.
            # wus2-jobruntimedata-prod-su1.azure-automation.net. IN CNAME wus2-jobruntimedata-prod-arm-1.trafficmanager.net.
            # wus2-containerservice-prod-su1.azure-automation.net.	CNAME	wus2-containerservice-prod-1.trafficmanager.net.
            # wus2-containerservice-test-su1.azure-automation.net.	CNAME	wus2-containerservice-test-1.trafficmanager.net.
            # wus2-agentservice-prod-1.azure-automation.net IN CNAME wus2-agentservice-prod-1.trafficmanager.net.
            # s15events.azure-automation.net. IN CNAME wus2-events-prod-arm-1.trafficmanager.net.

            # $hostedServiceName = $hostedServices[0].Name
            $tmProfileName = $null
            switch ($microservice) {
                DSC { $tmProfileName = "$($newLocation.ShortName.ToLower())-agentservice-prod-arm-1".ToLower() }
                WebHooks { $tmProfileName = "$($newLocation.ShortName.ToLower())-events-prod-arm-1".ToLower() }
                JRDS { $tmProfileName = "$($newLocation.ShortName.ToLower())-jobruntimedata-prod-arm-1".ToLower() }
                WebService { $tmProfileName = "$($newLocation.ShortName.ToLower())-oaaswebservice-prod-arm-1".ToLower() }
                # Portal { $tmProfileName = 'portals2.azure-automation'.ToLower() }
                Container { 
                    $tmProfileName += "$($newLocation.ShortName.ToLower())-containerservice-prod-1".ToLower() 
                    $tmProfileName += "$($newLocation.ShortName.ToLower())-containerservice-test-1".ToLower() 
                }
                # Default { Write-Error -Message "$microservice not recognized" }
                Default {  }
            }
            foreach ($tmProfile in $tmProfileName) {
                if (![bool](Get-AzureRmTrafficManagerProfile -Name $tmProfile -ResourceGroupName $tmProfile -ErrorAction SilentlyContinue)) {
                    Write-Verbose -Message "Creating Traffic Manager profile $tmProfile"
                    if ($tmProfile -contains 'prod') {
                        New-OaaSArmTrafficManagerProfile -ProfileName $tmProfile -ResourceGroupName $tmProfile -Location $newLocation.ExtendedName `
                            -TrafficRoutingMethod Weighted -Endpoints "$($hostedServices[0].Name).cloudapp.net", "$($hostedServices[1].Name).cloudapp.net"
                    }
                    else {
                        New-OaaSArmTrafficManagerProfile -ProfileName $tmProfile -ResourceGroupName $tmProfile -Location $newLocation.ExtendedName `
                            -TrafficRoutingMethod Weighted -Endpoints "$($hostedServices[1].Name).cloudapp.net", "$($hostedServices[0].Name).cloudapp.net"
                    }
                }
                else {
                    Write-Information -MessageData "Traffic Manager profile $tmProfile already exists, skipping"
                }
            }
        }


        
        #############################################################
        ## CERTIFICATES
        if ($Certificate) {
            $certificates = $serviceXmlFile.Service.Settings.Certificates.Certificate
            if ($certificates.Count -gt 0) {
                # need to temporarily switch subscription
                Write-Verbose -Message "Provisioning certificates"
                Select-OaaSSubscription MGMT | Out-Host
                $owner = '"redmond\asttest;redmond\blddeslf;redmond\RCG-Read Write-CG-16096;redmond\wadiuser;redmond\ws-disa"'

                foreach ($cert in $certificates) {
                    if ($cert.SecretStoreCertificatePath -contains $NewRegion) {
                        Write-Verbose -Message ""
                        $subjectName = $null
                        $subjectName
                        $subjectAlternativeNames = $null
                        $subjectAlternativeNames

                        $secret = $null
                        $stashClientCmd = $null
                        $secret = .\GetCertificates.ps1 -SecretName $cert.SecretStorecertificatePath -SubjectName $subjectName -SubjectAlternativeNames $subjectAlternativeNames -OutputFolder $OutputFolder
                        $stashClientCmd = ".\stashclient -env:prod cadd -owner:$owner -name:$($secret.SecretName) -filepath:$($secret.PfxFilePath) -password:$($secret.Password)"
                        Out-File -Encoding ascii -Append -InputObject $stashClientCmd -FilePath $stashClient
                    }
                }

                # switch back to the regional subscription
                Select-OaaSSubscription -Geo $NewRegion | Out-Null
                Write-Output -InputObject "Secret Store commands saved to $stashClient"
            }
        }
        



        
        #############################################################
        # UPDATE THE SERVICE XML
        if ($updateServiceXml) {
            Out-File -FilePath $newServiceXml -Encoding ascii -InputObject $serviceXmlFile -Force -ErrorAction Inquire
        }


        ## TODO: mds configuration
    }
}