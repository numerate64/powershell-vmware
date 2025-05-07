$ERROR_TAG = "ERROR"
$standalone = ""

class VsanLicenseInfoCalculator {
    # Vsan Cluster License Information
    static [pscustomobject] VsanClusterLicenseInfo($clusterName, $requiredCapacity) {
        return [pscustomobject] @{
            CLUSTER = $clusterName;
            REQUIRED_VSAN_TIB_CAPACITY = $requiredCapacity;
        }
    }

    # Host License Information
    static [pscustomobject] ComputeLicenseInfo($clusterName, $vmhostName, $sockets, $coresPerSocket, $vsphereLicenseCount, $vsanEntitledTiB, $numHosts) {
        return [pscustomobject] @{
            CLUSTER = $clusterName;
            VMHOST = $vmhostName;
            NUM_CPU_SOCKETS = $sockets;
            NUM_CPU_CORES_PER_SOCKET = $coresPerSocket;
            FOUNDATION_LICENSE_CORE_COUNT = $vsphereLicenseCount;
            VSAN_LICENSE_TIB_COUNT = $vsanEntitledTiB;
            NUM_HOSTS = $numHosts;
        }
    }

    static [pscustomobject] ComputeLicenseInfo($clusterName, $vmhostName, $sockets, $coresPerSocket, $vsphereLicenseCount, $vsanEntitledTiB) {
        return [VsanLicenseInfoCalculator]::ComputeLicenseInfo(
                   $clusterName, $vmhostName, $sockets, $coresPerSocket, $vsphereLicenseCount, $vsanEntitledTiB, 1)
    }

    static [int] GetEntitledFoundationLicenseCore($vsanTotalCPUCores, $vsanTotalHostCount, $vsanTotalCPUCount) {
        # Calculate required foundation license count which is where 0.25TiB/1TiB will be calculated from
        if($vsanTotalCPUCores -le 16) {
            $entitledFoundationLicenseCore = $vsanTotalHostCount * $vsanTotalCPUCount * 16
        } else {
            $entitledFoundationLicenseCore =  $vsanTotalHostCount * $vsanTotalCPUCount * $vsanTotalCPUCores
        }
        return $entitledFoundationLicenseCore
    }

    static [float] GetEntitledVsanTib($DeploymentType, $vsphereLicenseCount) {
        if($DeploymentType -eq "VCF") {
            $entitledVsanTib = ($vsphereLicenseCount * 1)
        } elseif($DeploymentType -eq "VVF") {
            $entitledVsanTib = ($vsphereLicenseCount * 0.25)
        } else {
            $entitledVsanTib = 0
        }
        return $entitledVsanTib
    }

    static [float] GetTotalRequiredVsanTiBLicenseCount($vsanLicenseTibCount, $entitledVsanTib) {
        $totalRequiredVsanTiBLicenseCount = ((0, $vsanLicenseTibCount)|Measure-Object -Maximum).Maximum
        $totalRequiredVsanTiBLicenseCount = ($totalRequiredVsanTiBLicenseCount - $entitledVsanTib)

        return $totalRequiredVsanTiBLicenseCount
    }

    static [array] BuildSummaryRow($inputdata, $unhealthy=$false) {
        $data = $inputdata | Sort-Object -Property CLUSTER

        # Dynamically handle properties
        $summaryRow = [ordered]@{}
        $inputdata[0].PSObject.Properties.Name | ForEach-Object {
            if ($_ -eq "FOUNDATION_LICENSE_CORE_COUNT") {
                $summaryRow[$_] = [int]($data | Measure-Object -Property $_ -Sum).Sum
            } elseif ($_ -eq "VSAN_LICENSE_TIB_COUNT" -or
                      $_ -eq "REQUIRED_VSAN_TIB_CAPACITY") {
                    if ($unhealthy -eq $true) {
                        $summaryRow[$_] = $ERROR_TAG
                    } else {
                        $total = ($data | Measure-Object -Property $_ -Sum).Sum
                        $summaryRow[$_] = $total
                    }
            } elseif ($_ -eq "CLUSTER") {
                $summaryRow[$_] = "Total"
            } else {
                $summaryRow[$_] = "-"
            }
        }

        # Append the summary row
        $data = @($data) + [pscustomobject]$summaryRow
        return $data
    }

    static [int] GetTotalRequiredComputeLicense($computeResults) {
        return ($computeResults.FOUNDATION_LICENSE_CORE_COUNT|Measure-Object -Sum).Sum
    }

    static [int] GetTotalRequiredVsanLicense($computeResults, $vsanResults) {
        $vsanTiBFromAllHosts = [int](($computeResults.VSAN_LICENSE_TIB_COUNT|Measure-Object -Sum).Sum)
        return [int](($vsanResults.REQUIRED_VSAN_TIB_CAPACITY|Measure-Object -Sum).Sum) - $vsanTiBFromAllHosts
    }
}

Class OutputUtils {
    static [array] AdjustClusterComputeInfoTable($computeResults) {
       return $computeResults | Select-Object CLUSTER, NUM_HOSTS, @{ Expression = { $_.NUM_CPU_SOCKETS }; label="NUM_CPU_SOCKETS_PER_HOST" }, NUM_CPU_CORES_PER_SOCKET, FOUNDATION_LICENSE_CORE_COUNT, VSAN_LICENSE_TIB_COUNT
    }

    static [array] AdjustHostComputeInfoTable($computeResults) {
       return $computeResults | Select-Object CLUSTER, VMHOST, NUM_CPU_SOCKETS, NUM_CPU_CORES_PER_SOCKET, FOUNDATION_LICENSE_CORE_COUNT, VSAN_LICENSE_TIB_COUNT
    }

    static [array] PrintVsanResultTable($vsanResults) {
        return $vsanResults | ft CLUSTER, @{
                   Name = 'REQUIRED_VSAN_TIB_CAPACITY';
                   Expression = { "{0:F0}" -f $_.REQUIRED_VSAN_TIB_CAPACITY };
                   Alignment = 'Right'
               } -AutoSize
    }

    static [array] PrintComputeResultTable($computeResults, $isHost) {
        if ($isHost) {
            return $computeResults | Format-Table CLUSTER, VMHOST, NUM_CPU_SOCKETS, NUM_CPU_CORES_PER_SOCKET, FOUNDATION_LICENSE_CORE_COUNT,  @{
                       Name = 'VSAN_LICENSE_TIB_COUNT';
                       Expression = { "{0:F2}" -f $_.VSAN_LICENSE_TIB_COUNT };
                       Alignment = 'Right'
                   } -AutoSize
        } else {
            return $computeResults | Format-Table CLUSTER, NUM_HOSTS, NUM_CPU_SOCKETS_PER_HOST, NUM_CPU_CORES_PER_SOCKET, FOUNDATION_LICENSE_CORE_COUNT, @{
                       Name = 'VSAN_LICENSE_TIB_COUNT';
                       Expression = { "{0:F2}" -f $_.VSAN_LICENSE_TIB_COUNT };
                       Alignment = 'Right'
                   } -AutoSize
        }
    }

    static [void] SaveToCsv($results, $csvFileName) {
        $results | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath $csvFileName
    }
}


Function Get-FoundationCoreAndTiBUsage {
<#
    .DESCRIPTION Retrieves CPU Core/Storage usage analysis for vSphere Foundation (VVF) and VMware Cloud Foundation (VCF)
    .NOTES  Author:  William Lam, Broadcom
    .NOTES  Last Updated: 02/12/2024
    .PARAMETER ClusterName
        Name of a specific vSphere Cluster
    .PARAMETER CSV
        Output to CSV file
    .PARAMETER Filename
        Specific filename to save CSV file (default: <vcenter name>.csv and <vcenter name>-vsan.csv)
    .PARAMETER CollectLicenseKey
        Collect ESXi and/or vSAN License Key for each host
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -DeploymentType VCF
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -DeploymentType VVF
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -ClusterName "ML Cluster" -DeploymentType VCF
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -ClusterName "ML Cluster" -DeploymentType VCF -CSV
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -ClusterName "ML Cluster" -DeploymentType VCF -CSV -Filename "ML Cluster-Cluster.csv"
    .EXAMPLE
        Get-FoundationCoreAndTiBUsage -ClusterName "ML Cluster" -DeploymentType VCF -CollectLicenseKey
#>
    param(
        [Parameter(Mandatory=$false)][string]$ClusterName,
        [Parameter(Mandatory=$false)][string]$Filename,
        [Parameter(Mandatory=$true)][ValidateSet("VCF","VVF")][String]$DeploymentType,
        [Switch]$Csv,
        [Switch]$CollectLicenseKey,
        [Switch]$DemoMode
    )

    # Helper Function to build out Computer usage object
    Function BuildFoundationUsage {
        param(
            [Parameter(Mandatory=$false)]$cluster,
            [Parameter(Mandatory=$true)]$vmhost,
            [Parameter(Mandatory=$false)][Boolean]$CollectLicenseKey,
            [Parameter(Mandatory=$false)][Boolean]$DemoMode
        )

        if($cluster -eq $null) {
            $cluster = (Get-Cluster -VMHost (Get-VMHost -Name $vmhost.name)).ExtensionData

            # Determine if ESXi is in cluster
            if($cluster -ne $null) {
                $clusterName = $cluster.name
            } else {
                $clusterName = $standalone
            }
        } else {
            $clusterName = $cluster.name
        }

        $vmhostName = $vmhost.name

        $sockets = $vmhost.Hardware.CpuInfo.NumCpuPackages
        $coresPerSocket = ($vmhost.Hardware.CpuInfo.NumCpuCores / $sockets)

        # Check if hosts is running vSAN
        if($vmhost.Runtime.VsanRuntimeInfo.MembershipList -ne $null) {
            $vsanClusters[$clusterName] = 1
        } else {
            if ($clusterName -ne $standalone) {
                $nonVsanClusters[$clusterName] =  1
            }
        }

        # vSphere & vSAN
        $vsphereLicenseCount = [VsanLicenseInfoCalculator]::GetEntitledFoundationLicenseCore(
            $coresPerSocket, 1, $sockets)
        $vsanEntitledTiB = [VsanLicenseInfoCalculator]::GetEntitledVsanTib(
            $DeploymentType, $vsphereLicenseCount)


        # Collect vSphere and vSAN License Key
        $vsphereLicenseKey = "N/A"
        $vsanLicenseKey = "N/A"

        if($CollectLicenseKey) {
            $hostLicenses = $licenseAssignementManager.QueryAssignedLicenses($vmhost.MoRef.Value)
            foreach ($hostLicense in $hostLicenses) {
                if($hostLicense.AssignedLicense.EditionKey -match "esx") {
                    $vsphereLicenseKey = $hostLicense.AssignedLicense.LicenseKey
                    break
                }
            }

            if($isVSANHost) {
                $clusterLicenses = $licenseAssignementManager.QueryAssignedLicenses($cluster.MoRef.Value)

                foreach ($clusterLicense in $clusterLicenses) {
                    if($clusterLicense.AssignedLicense.EditionKey -match "vsan") {
                        $vsanLicenseKey = $clusterLicense.AssignedLicense.LicenseKey
                        break
                    }
                }
            }

            # demo purpose without print license keys
            if($DemoMode) {
                if($vsphereLicenseKey -notmatch "00000" -and $vsphereLicenseKey -notmatch "N/A") {
                    $vsphereLicenseKey = "DEMO!-DEMO!-DEMO!-DEMO!-DEMO!"
                }

                if($vsanLicenseKey -notmatch "0000" -and $vsanLicenseKey -notmatch "N/A") {
                    $vsanLicenseKey = "DEMO!-DEMO!-DEMO!-DEMO!-DEMO!"
                }
            }
        }

        $tmp = [VsanLicenseInfoCalculator]::ComputeLicenseInfo(
                   $clusterName,
                   $vmhostName,
                   $sockets,
                   $coresPerSocket,
                   $vsphereLicenseCount,
                   $vsanEntitledTiB)

        if($CollectLicenseKey) {
            $tmp | Add-Member -NotePropertyName VSPHERE_LICENSE_KEY -NotePropertyValue $vsphereLicenseKey
            $tmp | Add-Member -NotePropertyName VSAN_LICENSE_KEY -NotePropertyValue $vsanLicenseKey
        }

        return $tmp
    }

    # Helper Function to build out vSAN usage object
    Function BuildvSANUsage {
        param(
            [Parameter(Mandatory=$false)][string]$ClusterName
        )

        $vsanLicenseTibRequired = Get-VsanClusterCapacity -ClusterName $ClusterName
        Write-Debug "`nGet-VsanClusterCapacity for cluster $ClusterName $vsanLicenseTibRequired"

        if ($vsanLicenseTibRequired -eq -1) {
            $vsanLicenseTibRequired = $ERROR_TAG
        } else {
            # Round up required vSAN TiB capacity
            $vsanLicenseTibRequired = [int][math]::Ceiling($vsanLicenseTibRequired)
        }

        $tmpVsanResult = [VsanLicenseInfoCalculator]::VsanClusterlicenseInfo(
                            $clusterName, $vsanLicenseTibRequired)
        return $tmpVsanResult
    }

    Function BuildNonVsanUsage {
        param(
            [Parameter(Mandatory=$false)][string]$ClusterName
        )

        $tmp = [VsanLicenseInfoCalculator]::VsanClusterlicenseInfo($clusterName, 0)
        return $tmp
    }

    Function Get-VsanClusterCapacity {
        param (
            [Parameter(Mandatory=$true)][string]$ClusterName
        )
        Function QueryVcClusterHealthSummary {
            param (
                [Parameter(Mandatory=$true)]$clusterRef
            )
            $VsanVcClusterHealthSystem = Get-VsanView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system"
            $summary = $VsanVcClusterHealthSystem.VsanQueryVcClusterHealthSummary($clusterRef, $null, $null, $null, $null, $null, 'defaultView')
            return $summary
        }
        Function GetDiskGroupCacheDisks{
           param (
               [Parameter(Mandatory=$true)]$hostname
           )
           $diskGroups = Get-VsanDiskGroup -VMHost $hostname
           Write-Debug ($diskGroups | format-list | Out-String)
           return @(foreach ($dg in $diskGroups) {
                        $dg.ExtensionData.ssd.canonicalName
                    })
        }
        Function CaculateVsanCapacityByDisks {
            param (
                [Parameter(Mandatory=$true)]$cluster,
                [Parameter(Mandatory=$true)]$isEsa
            )
            Function ValidateHostsHealth {
                param (
                    [Parameter(Mandatory=$true)]$vmHosts
                )
                foreach ($vmhost in $vmHosts) {
                   if ($vmhost.ConnectionState -ne "Connected" -and $vmhost.ConnectionState -ne "Maintenance") {
                      Write-Host "Host $vmhost is not connected. All hosts must be connected." -ForegroundColor Red
                      return $false
                   }
                }
                return $true
            }

            $healthSummary = QueryVcClusterHealthSummary -clusterRef $cluster.MoRef
            $physicalDiskHealth = $healthSummary.physicalDisksHealth

            $totalCapacity = 0
            if ($physicalDiskHealth -eq $null) {
                # Empty cluster
                Write-Debug "Empty cluster"
                return $totalCapacity
            }

            $vmHosts = Get-Cluster -Name $cluster.Name | Get-VMHost
            $isHostHealthy = ValidateHostsHealth -vmHosts $vmHosts
            if ($isHostHealthy -eq $false) {
                return -1
            }

            Write-Debug "Hosts under cluster $vmHosts"

            $vmHostNames = @(foreach ($vmhost in $vmHosts) {$vmhost.Name})
            foreach ($hostPhysicalDiskHealth in $physicalDiskHealth) {
                $hostname = $hostPhysicalDiskHealth.hostname
                Write-Debug "Calculating capacity on host $hostname ..."
                if ($vmHostNames.contains($hostname) -eq $false) {
                    # The host is not under cluster
                    Write-Debug "Host $hostname is not under cluster, skip"
                    continue
                }
                Write-Debug ($hostPhysicalDiskHealth | format-list | Out-String)
                if ($hostPhysicalDiskHealth.error) {
                    Write-Host "Unable to collect disk information from host $hostname in cluster $cluster.Name. See vSAN Health for additional information." -ForegroundColor Red
                    return -1
                }

                $disks = $hostPhysicalDiskHealth.disks
                if ($disks -eq $null) {
                   continue
                }

                if ($isEsa -eq $false) {
                   $cacheDisks = GetDiskGroupCacheDisks -hostname $hostname
                   Write-Debug "Get cache disks: $cacheDisks"
                }

                Write-Debug ($disks | format-list | Out-String)
                foreach ($disk in $disks) {
                   if ($isEsa -eq $false) {
                       # For osa, ignore cache disk
                       $diskname = if ($disk.ScsiDisk -and $disk.ScsiDisk.canonicalName) {$disk.ScsiDisk.canonicalName} else {$disk.name}
                       if ($cacheDisks.contains($diskname)) {
                           continue
                       }
                   }
                   $capacity = $disk.ScsiDisk.capacity
                   $size = $capacity.block * $capacity.blockSize
                   $totalCapacity += $size
                }
            }

            Write-Debug "Total disk capacity $totalCapacity"
            return $totalCapacity
        }
        Function IsHostsOver {
            param (
                [Parameter(Mandatory=$true)]$clusterName,
                [Parameter(Mandatory=$true)]$hostVersion
            )
            $vmHosts = Get-Cluster -Name $clusterName | Get-VMHost
            foreach ($vmhost in $vmHosts) {
                if ([System.Version]($vmhost.Version) -lt [System.Version]$hostVersion) {
                    return $false
                }
            }
            return $true
        }

        Write-Debug "Calculating vSAN claimed capacity ..."

        $clusterEntity = Get-Cluster -Name $ClusterName
        $cluster = $clusterEntity.ExtensionData

        $isVsanEsa = $false
        if ($clusterEntity.VsanEsaEnabled -ne $null) {
            $isVsanEsa = $clusterEntity.VsanEsaEnabled
        }

        $diskCapacity = CaculateVsanCapacityByDisks -cluster $cluster -isEsa $isVsanEsa
        if ($diskCapacity -eq -1) {
            Write-Debug "Failed to calculate total disk capacity for cluster $ClusterName. See vSAN Health for additional information."
            return -1
        }

        $vcVersion = $global:DefaultVIServers.version

        # For vc 80u3 and newer version, get claimed capacity by API directly.
        if ([System.Version]$vcVersion -ge [System.Version]'8.0.3') {
           $requiredCliVersion = "13.3"
           $powercli = Find-Module -Name VMware.PowerCLI
           if ($powercli -eq $null -Or [System.Version]($powercli.Version) -lt [System.Version]$requiredCliVersion) {
               Write-Error "The script cannot be run because the version of VMware.PowerCLI is less than $requiredCliVersion" -ErrorAction Stop
           }

           $VsanVcClusterConfig = Get-VsanView -Id "VsanVcClusterConfigSystem-vsan-cluster-config-system"
           $claimedCapacity = $VsanVcClusterConfig.VsanClusterGetClaimedCapacity($cluster.MoRef)
           Write-Debug "Claimed cluster capacity $claimedCapacity"

           if ($claimedCapacity -ne $diskCapacity) {
               $isOver = IsHostsOver -ClusterName $ClusterName -hostVersion '8.0.3'
               if ($isOver) {
                   Write-Host "The vSAN capacity for cluster $ClusterName cannot be determined because of possible stale PDL devices in this cluster. Contact Global Support team for assistance." -ForegroundColor Red
               } else {
                   Write-Host "Failed to calculate total disk capacity for cluster $ClusterName. Contact Global Support team for assistance." -ForegroundColor Red
               }
               return -1
           }
        } else {
            $claimedCapacity = $diskCapacity
        }

        $claimedCapacityInTiB = $claimedCapacity / 1024.0 / 1024 / 1024 / 1024 # Convert bytes->TiB
        Write-Debug "Claimed capacity: $claimedCapacityInTiB TiB"
        return $claimedCapacityInTiB
    }

    $results = @()
    $clusterResults = @()
    $tmpResults = @()
    $vsanClusters = @{}
    $nonVsanClusters = @{}
    $healthClusters = @()
    $unhealthClusters = @()

    if($CollectLicenseKey) {
        $licenseManager = Get-View $global:DefaultVIServer.ExtensionData.Content.LicenseManager
        $licenseAssignementManager = Get-View $licenseManager.licenseAssignmentManager
    }

    if($ClusterName) {
        try {
            Get-Cluster -Name $ClusterName -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "`nCluster with name '$ClusterName' was not found`n" -ForegroundColor Red
            break
        }

        Write-Host "`nQuerying vSphere Cluster: $ClusterName`n"  -ForegroundColor cyan

        $clusters = Get-View -ViewType ClusterComputeResource -Property Name,Host,ConfigurationEx -Filter @{"name"=$ClusterName}
        foreach ($cluster in $clusters) {
            try {
                $vmhosts = Get-View $cluster.host -Property Name,Hardware.systemInfo,Hardware.CpuInfo,Runtime
            } catch {
                continue
            }
            foreach ($vmhost in $vmhosts) {
                # Ingore HCX IX & vSAN Witness Node
                if($vmhost.Hardware.systemInfo.Model -ne "VMware Mobility Platform" -and (Get-AdvancedSetting -Entity $vmhost.name Misc.vsanWitnessVirtualAppliance).Value -eq 0) {
                    $result = BuildFoundationUsage -cluster $cluster -vmhost $vmhost -CollectLicenseKey $CollectLicenseKey -DemoMode $DemoMode
                    $tmpResults += $result
                    $results += $result
                }
            }

            # vSAN Storage Usage
            if($cluster.ConfigurationEx.VsanConfigInfo.Enabled) {
                $tmpVsanResult = BuildvSANUsage -ClusterName $ClusterName

                if ($tmpVsanResult.REQUIRED_VSAN_TIB_CAPACITY -eq $ERROR_TAG) {
                    $unhealthClusters += $ClusterName
                } else {
                    $healthClusters += $ClusterName
                }

                $clusterResults += $tmpVsanResult
            } else {
                $tmpNonVsanResult = BuildNonVsanUsage -ClusterName $ClusterName
                $clusterResults += $tmpNonVsanResult
            }
        }
    } else {
        Write-Host "`nQuerying all ESXi hosts, this may take several minutes..." -ForegroundColor cyan

        $vmhosts = Get-View -ViewType HostSystem -Property Name,Hardware.systemInfo,Hardware.CpuInfo,Runtime
        $cluster = $null

        foreach ($vmhost in $vmhosts) {
            # Ingore HCX IX & vSAN Witness Node
            if($vmhost.Hardware.systemInfo.Model -ne "VMware Mobility Platform") {
                if ($vmhost.Runtime.ConnectionState -ne "connected" -or (Get-AdvancedSetting -Entity $vmhost.name Misc.vsanWitnessVirtualAppliance).Value -eq 0) {

                    $result = BuildFoundationUsage -cluster $cluster -vmhost $vmhost -CollectLicenseKey $CollectLicenseKey -DemoMode $DemoMode

                    $tmpResults += $result
                    $results += $result
                }
            }
        }

        foreach ($key in $vsanClusters.keys) {
            $tmpVsanResult = BuildvSANUsage -ClusterName $key

            if ($tmpVsanResult.REQUIRED_VSAN_TIB_CAPACITY -eq $ERROR_TAG) {
                $unhealthClusters += @($key)
            } else {
                $healthClusters += $key
            }

            $clusterResults += $tmpVsanResult
        }

        foreach ($key in $nonVsanClusters.keys) {
            $tmpNonVsanResult = BuildNonVsanUsage -ClusterName $key
            $clusterResults += $tmpNonVsanResult
        }

    }

    $deploymentTypeString = @{
        "VCF" = "VMware Cloud Foundation (VCF) Instance"
        "VVF" = "VMware vSphere Foundation (VVF)"
    }

    Write-Host -ForegroundColor Yellow "`nSizing Results for $($deploymentTypeString[$DeploymentType]):"

    if($CSV) {
        If(-Not $Filename) {
            $Filename = "$($global:DefaultVIServer.Name).csv"
        }

        Write-Host "`nSaving output as CSV file to $Filename`n"
        $t1 = [VsanLicenseInfoCalculator]::BuildSummaryRow($results, $false)
        $t1 = [OutputUtils]::AdjustHostComputeInfoTable($t1)

        [OutputUtils]::SaveToCsv($t1, $Filename)

        if($clusterResults.count -gt 0) {
            $vsanFileName = $Filename.replace(".csv","-vsan.csv")
            Write-Host "Saving output as CSV file to $vsanFileName`n"
            $isUnhealthy = if ($unhealthClusters.Count -gt 0) { $true } else { $false }
            $t2 =[VsanLicenseInfoCalculator]::BuildSummaryRow($clusterResults, $isUnhealthy)

            [OutputUtils]::SaveToCsv($t2, $vsanFileName)
        }
    } else {
        Write-Host "`nHost Information" -ForegroundColor Magenta
        if (($results | measure).Count -eq 0)  {
            Write-Host "`nESXi Hosts were not found with searching criteria`n" -ForegroundColor Red
        } else {
            $t1 = [VsanLicenseInfoCalculator]::BuildSummaryRow($results, $false)
            $t1 = [OutputUtils]::AdjustHostComputeInfoTable($t1)

            [OutputUtils]::PrintComputeResultTable($t1, $true)
        }
        if($clusterResults.count -gt 0) {
            Write-Host "Cluster Information" -ForegroundColor Magenta
            $isUnhealthy = if ($unhealthClusters.Count -gt 0) { $true } else { $false }
            $t2 = [VsanLicenseInfoCalculator]::BuildSummaryRow($clusterResults, $isUnhealthy)

            [OutputUtils]::PrintVsanResultTable($t2)
        }
    }

    Write-Host "`Total Required $DeploymentType Compute Licenses: " -ForegroundColor cyan -NoNewline
    [VsanLicenseInfoCalculator]::GetTotalRequiredComputeLicense($results)

    Write-Host "Total Required vSAN Add-on Licenses: " -ForegroundColor cyan -NoNewline
    if ($unhealthClusters.Count -gt 0) {
        $ERROR_TAG
    } else {
        [VsanLicenseInfoCalculator]::GetTotalRequiredVsanLicense($results, $clusterResults)
    }

    Write-Host "`n"
}
