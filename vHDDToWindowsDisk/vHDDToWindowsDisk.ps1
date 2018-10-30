<#
    .SYNOPSIS
    Match Windows Disks to corresponding vHDD in VCenter

    .DESCRIPTION
    This script match Windows Disks to its corresponding vHDD in VCenter

    .PARAMETER vmName 
    Name of the VM

    .PARAMETER vCenter 
    vCenter host
	
	.PARAMETER outputDir
	Directory to output CSV, no trailing slash

    .EXAMPLE
    vHDDToWindowsDisk.ps1 -vmName "Server1" -vCenter "vCenter.local"
    Match vHDDs on Server1 to Windows Disks

	.EXAMPLE
    vHDDToWindowsDisk.ps1 -vmName "Server1" -vCenter "vCenter.local" -outputDir "C:\Misc"
    Match vHDDs on Server1 to Windows Disks and output CSV to C:\Misc
	
    .NOTES
    Name:           vHDDToWindowsDisk.ps1
    Version:        1.1
    Author:         Mark Southall

    .LINK
    https://github.com/MarkSouthall/PowershellScripts/blob/master/vHDDToWindowsDisk/vHDDToWindowsDisk.ps1 - adapted FMONs Script

    .PREREQUISITE
    - User for vCenter with appropriate rights
    - User for Get-WmiObject with appropriate rights
    - Current VMware Tools

#>

Param (
  [string]$vmName,
  [string]$vCenter,
  [string]$outputDir
)
Add-PSSnapin "Vmware.VimAutomation.Core" 
$cred = if ($cred){$cred}else{Get-Credential}  
Connect-VIServer -Server $vCenter -Credential $cred

## modification below here not necessary to run ##  
  
  
#get windows disks via wmi  
$win32DiskDrive  = Get-WmiObject -Class Win32_DiskDrive -ComputerName $vmName -Credential $cred
  
#get vm hard disks and vm datacenter and virtual disk manager via PowerCLI  
#does not connect to a vi server for you!  you should already be connected to the appropraite vi server.  
$vmHardDisks = Get-VM -Name $vmName | Get-HardDisk  
$vmDatacenterView = Get-VM -Name $vmName | Get-Datacenter | Get-View  
$virtualDiskManager = Get-View -Id VirtualDiskManager-virtualDiskManager  
  
#iterates through each windows disk and assign an alternate disk serial number value if not a vmware disk model  
#required to handle physical mode RDMs, otherwise this should not be needed  
foreach ($disk in $win32DiskDrive)  
{  
  #add a AltSerialNumber NoteProperty and grab the disk serial number  
  $disk | Add-Member -MemberType NoteProperty -Name AltSerialNumber -Value $null  
  $diskSerialNumber = $disk.SerialNumber  
	
  #if disk is not a VMware disk set the AltSerialNumber property  
  if ($disk.Model -notmatch 'VMware Virtual disk SCSI Disk Device')  
  {  
	#if disk serial number is 12 characters convert it to hex  
	if ($diskSerialNumber -match '^\S{12}$')  
	{  
	  $diskSerialNumber = ($diskSerialNumber | foreach {[byte[]]$bytes = $_.ToCharArray(); $bytes | foreach {$_.ToString('x2')} }  ) -join ''  
	}  
	$disk.AltSerialNumber = $diskSerialNumber  
  }  
}  
  
#iterate through each vm hard disk and try to correlate it to a windows disk  
#and generate some results!  
$results = @()  
foreach ($vmHardDisk in $vmHardDisks)  
{  
  #get uuid of vm hard disk / and remove spaces and dashes  
  $vmHardDiskUuid = $virtualDiskManager.queryvirtualdiskuuid($vmHardDisk.Filename, $vmDatacenterView.MoRef) | foreach {$_.replace(' ','').replace('-','')}  
  $hd = $vmHardDisk
  $ctrl = $hd.Parent.Extensiondata.Config.Hardware.Device | where{$_.Key -eq $hd.ExtensionData.ControllerKey}
  $scsiID = "$($ctrl.BusNumber):$($vmHardDisk.ExtensionData.UnitNumber)"
  #match vm hard disk uuid to windows disk serial number  
  $windowsDisk = $win32DiskDrive | where {$_.SerialNumber -eq $vmHardDiskUuid}  
	
  #if windowsDisk not found then try to match the vm hard disk ScsiCanonicalName to the AltSerialNumber set previously  
  if (-not $windowsDisk)  
  {  
	$windowsDisk = $win32DiskDrive | where {$_.AltSerialNumber -eq $vmHardDisk.ScsiCanonicalName.substring(12,24)}  
  }
  
  $deviceID = $windowsDisk.DeviceID.Replace("\","\\")
  $partitions = Get-WmiObject -query "Associators of {Win32_DiskDrive.DeviceID=""$deviceID""} WHERE AssocClass = Win32_DiskDriveToDiskPartition" -ComputerName $vmName -Credential $cred
  foreach ($partition in $partitions)
  {
	$partitionID = $Partition.DeviceID
	$logicalDisk = Get-WmiObject -query "Associators of {Win32_DiskPartition.DeviceID=""$partitionID""} WHERE AssocClass = Win32_LogicalDiskToPartition" -ComputerName $vmName -Credential $cred
	
	#generate a result  
    $result = "" | select vmName,
							vmHardDiskDatastore,
							vmHardDiskVmdk,
							vmHardDiskName,
							driveLetter,
							driveName,
							#windowsDiskIndex,
							#windowsDiskSerialNumber,
							#vmHardDiskUuid,
							#windowsDiskAltSerialNumber,
							#vmHardDiskScsiCanonicalName,
							scsiID
    $result.vmName = $vmName.toupper()  
    $result.vmHardDiskDatastore = $vmHardDisk.filename.split(']')[0].split('[')[1]  
    $result.vmHardDiskVmdk = $vmHardDisk.filename.split(']')[1].trim()  
    $result.vmHardDiskName = $vmHardDisk.Name  
	$result.driveLetter = $logicalDisk.Caption
	$result.driveName = $logicalDisk.VolumeName
    #$result.windowsDiskIndex = if ($windowsDisk){$windowsDisk.Index}else{"FAILED TO MATCH"}  
    #$result.windowsDiskSerialNumber = if ($windowsDisk){$windowsDisk.SerialNumber}else{"FAILED TO MATCH"}  
    #$result.vmHardDiskUuid = $vmHardDiskUuid  
    #$result.windowsDiskAltSerialNumber = if ($windowsDisk){$windowsDisk.AltSerialNumber}else{"FAILED TO MATCH"}  
    #$result.vmHardDiskScsiCanonicalName = $vmHardDisk.ScsiCanonicalName  
    $result.scsiID = $scsiID
    $results += $result  
  }
}  
  
#sort and then output the results  
if($outputDir)
{
  $outputFile = "${vmName}_drive_matches.csv"
  $outputFilePath = Join-Path $outputDir $outputFile
  $results | export-csv -path $outputFilePath
}
$results = $results | sort {[int]$_.vmHardDiskName.split(' ')[2]}  
$results | ft -AutoSize  
