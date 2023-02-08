# Veeam backups restorer to vApp. 
# Vasiliy Kuznetsov, FastLane RCIS, 2023
#
# Script to restore several backups (aka Pods) from veeam to vmware vApps.
# Beforehead you have to use library_import.ps1 due to the fact
# that backups made with it have their start order saved in DB.
#
# Args: 
# vcsa:
# 	VMware vSphere Appliance to work with
# vmwhost:
# 	VMware production host
# datastore:
# 	Connected to host datastore to place data
# veeamhost:
# 	Veeam Host address 
# ethname:
# 	Ethalon name (as stated in backup job)
# podsnumber:
# 	Pods quantity to be dispatched
# podstartindex:
# 	Starting Index of pods if it differs from 1

param($vcsa, $vmhost, $datastore, $veeamhost, $ethname, $podsnumber, $podstartindex)

Import-Module VMware.VimAutomation.Core
Import-Module SimplySql
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false

function Convert-VeeamEthalonNICNameToLabPodvSwitchName {
    param(
        $nicname,
        $podname
    )

    # 31 is the vswitch name limit. 7 is ".Pod0X.". Minus 1 to target at the last char
    $freelen = 31 - 7 - $nicname.Length - 1
    $shortpodname = (($podname -split "\.")[0][0..$freelen] -join "") + "." + ($podname -split "\.")[-1]
    $deploynetname = $shortpodname + "." + $nicname

    return $deploynetname
}

function New-vmWareRestoreResourcePool {
	param(
		$deployserver,
        $vmwhost,
        $podname,
		$deploydatastore,
		$ethalon,
		$vm_restorepoint,
		$strpodindex
	)
    
    $location = Get-VMHost -Name $vmwhost
    New-ResourcePool -Location $location -Name $podname	
	$rpool = Find-VBRViResourcePool -Server $deployserver -name $podname
	$sourcenets = @()
	$deploynets = @()
	# $nics = $vm_restorepoint[0].GetBackup().GetOIBS().Auxdata.Nics
	$nics = $ethalon.GetOIBS().Auxdata.Nics
	foreach($nic in $nics) {
		$sourcenets += $nic.Network
        $deploynetname = Convert-VeeamEthalonNICNameToLabPodvSwitchName -nicname $nic.Network.NetworkName -podname $podname
		$deploynetobj = Get-VBRViServerNetworkInfo -Server $deployserver | Where-Object { $_.NetworkName -eq $deploynetname }
		# If network is not added we suppose it as common like 'Cisco-labs' etc
		if ( -Not $deploynetobj ) {
			$deploynetobj = $nic.Network
		}
		$deploynets += $deploynetobj
	}
	Start-VBRRestoreVM -RestorePoint $vm_restorepoint[0] -Server $deployserver -ResourcePool $rpool -Datastore $deploydatastore  -SourceNetwork $sourcenets -TargetNetwork $deploynets
} #-EnableNetworkMapping

function Get-DBStoredBootOrder{
	param(
		$vappname
	)
	
	# Update Database 
	Open-MySqlConnection -Server "127.0.0.1" -Database "vmware-backups" -UserName "YourUserHere" -Password "YourPWHere" 
	$sqlquerry = "SELECT orderdata FROM startorder WHERE vAppName=@vappname;"
	$fullstring = Invoke-SqlQuery -Query $sqlquerry -Parameters @{vappname = $vappname} 
	Close-SqlConnection


	# Parse SQL response
	$bootorder = @{}
    $prelastcharid = $fullstring[0].length - 2
	$fullstring = $fullstring[0][0..$prelastcharid] -join ""
	$iskey = $true
	$key = ""
	foreach ($str in ($fullstring -split "~")) {
		if($iskey) {
			$iskey = $false
			$key = $str
            if ( -Not $bootorder[$key] ) {
                $bootorder[$key] = @()
                }
		} else {
			$iskey = $true
			$str = $str -split "^"
            $bootorder[$key] += $str[1..$str.Length]
		}
	}
	return $bootorder
}

function Write-NetworkNameTemplates { 
    param (
        $ethalon
    )

    $nictemplatelist = @()
    $podnametemplate = $ethalon.Name + ".Pod00"
    foreach ($nic in $ethalon.GetOIBS().Auxdata.Nics) {
        $nictemplatelist += Convert-VeeamEthalonNICNameToLabPodvSwitchName -nicname $nic.Network.NetworkName -podname $podnametemplate
    }
    Write-Output $nictemplatelist
    Read-Host -Prompt "Press any key to continue"
}

function Convert-DBStoredBootOrderToSpecvmOrder {
	param(
		$bootorder
	)
	
	$vmOrder = New-Object System.Collections.ArrayList
	foreach ($key in $bootorder.keys) {
		$vmOrder.Add(@{
			Group = $key
			VM = $bootorder[$key]
		})
	}
	return $vmOrder
}

function Set-vmWarevAppBootOrder {
	param(
		$vapp,
		$bootorder
	)
	
	$vmOrder = Convert-DBStoredBootOrderToSpecvmOrder -bootorder $bootorder
	$spec = New-Object VMware.Vim.VAppConfigSpec
	$spec.EntityConfig = $vapp.ExtensionData.VAppConfig.EntityConfig
	foreach($group in $vmOrder){
		$spec.EntityConfig | where{$group.VM -contains $_.Tag} | %{
			$_.StartOrder = $group.Group
		}
	}
	$vapp.ExtensionData.UpdateVAppConfig($spec)
}

function Move-vmWareResourcePoolContentsTovApp {
	param(
		$podname,
        $vmwhost,
		$deployserver,
		$FolderContainer,
		$bootorder
	)
	$vappname = $podname + "-vApp"
    $location = Get-VMHost -Name $vmwhost
	New-VApp -Location $location -Name $vappname -InventoryLocation $FolderContainer
    # Yes, New-VApp return vApp instance. But if it fails for any reason it won't. Duplicate is case for fail
    $vapp = Get-VApp -Name $vappname
	$rp = Get-ResourcePool -Name $podname
	foreach ($vm in $rp.ExtensionData.Vm) {
        $vmobj = Get-VM -Id $vm 
		Move-VM -VM $vmobj -Destination $vapp
	}
    Remove-ResourcePool -ResourcePool $rp
	Set-vmWarevAppBootOrder -vapp $vapp -bootorder $bootorder
}

# https://www.veeam.com/kb1489
# Add-PSSnapin VeeamPSSnapin


Connect-VBRServer -server $veeamhost
While(-Not (Connect-VIServer -Server $vcsa -Protocol https)) {
    Write-Output "Error. Try again."
}

$podstartindex = $(If ($podstartindex) {$podstartindex} else {1})
#$podsnumer = 3

$deployserver = Get-VBRServer -Name $vmwhost
$deploydatastore = Find-VBRViDatastore -Server $deployserver -Name $datastore

$bootorder = Get-DBStoredBootOrder -vappname $vappname

$ethalon = Get-VBRBackup -Name $ethname
$FolderContainer = Get-Folder -Name "Labs"

Write-NetworkNameTemplates -ethalon $ethalon


for ( $podidx = $podstartindex; $podidx -le $podsnumber; $podidx++ ) {
	$strpodindex = $(If ($podidx -lt 10) {"0"} Else {""}) + $podidx.ToString()
    $podname = $ethalon.Name + ".Pod" + $strpodindex
	foreach($vm_restorepoint in Get-VBRRestorePoint -Backup $ethalon) {	
		New-vmWareRestoreResourcePool -deployserver $deployserver -vmwhost $vmwhost -deploydatastore $deploydatastore -ethalon $ethalon -vm_restorepoint $vm_restorepoint -podname $podname -strpodindex $vm_restorepoint
		}
    Move-vmWareResourcePoolContentsTovApp -podname $podname -vmwhost $vmwhost -deployserver $deployserver -FolderContainer $FolderContainer -bootorder $bootorder
}
