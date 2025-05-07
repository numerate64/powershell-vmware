# powershell-vmware

In order to use the script, perform the following:

Connect to vCenter Server:
- Connect-VIServer -Server vCenter_Server 
Import PowerCLI function: 
- Import-Module .\FoundationCoreAndTiBUsage.psm1 
Run Get-FoundationCoreAndTiBUsage function and specify deployment type to retrieve results. By default, the script will iterate through all vSphere Clusters.
- Get-FoundationCoreAndTiBUsage -DeploymentType VCF
- Get-FoundationCoreAndTiBUsage -DeploymentType VVF 
