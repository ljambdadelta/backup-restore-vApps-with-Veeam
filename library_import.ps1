# Veeam backuper with future restoring to vApps. 
# Vasiliy Kuznetsov, FastLane RCIS, 2023
#
# Script backups vApp to veeam and saves its VMs' power on order
#
# Args: 
# vcsa:
# 	VMware vSphere Appliance to work with
# vappname:
#	vApp that ought to be backed up
# veeamhost:
# 	Veeam Host address 
# jobname:
#	Name for newly created backup job

param($vcsa, $vappname, $veeamhost, $jobname)

Import-Module VMware.VimAutomation.Core
Import-Module SimplySql
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false

# vSphere communication
Connect-VIServer -Server $vcsa -Protocol https
$vmwvapp = Get-VApp -Name $vappname
$bootorderdict = @{}
foreach ($vmwvappvm in $vmwvapp.ExtensionData.VAppConfig.EntityConfig) {
	$bootorder = $vmwvappvm.StartOrder 
	if ( -Not ($bootorderdict.keys -contains $bootorder) ) {
		$bootorderdict[$bootorder] = New-Object Collections.Generic.List[string]
	}
	$bootorderdict[$bootorder].Add($vmwvappvm.Tag)
}

# Update Database 
Open-MySqlConnection -Server "127.0.0.1" -Database "vmware-backups" -UserName "YourUserHere" -Password "YourPWHere" 
$zip= ""
foreach ($key in $bootorderdict.keys) {
	$val = $bootorderdict[$key] -Join "^"
	$zip = $zip + $key + "~" + $val + "~"
}
$sqlquerry = "INSERT INTO startorder (vAppName, orderdata) VALUES (@vappname, @dict) ON DUPLICATE KEY UPDATE orderdata=@dict;"
Invoke-SqlQuery -Query $sqlquerry -Parameters @{vappname = $vappname; dict = $zip} 
Close-SqlConnection


# Veeam communication
Connect-VBRServer -server $veeamhost
$repository = Get-VBRBackupRepository
$vappentity = Find-VBRViEntity -Name $vappname
$job = Add-VBRViBackupJob -Name $jobname -Entity $vappentity -BackupRepository $repository
Start-VBRJob $job
