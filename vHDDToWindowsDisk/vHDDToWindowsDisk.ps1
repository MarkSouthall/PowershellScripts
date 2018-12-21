<#
    .SYNOPSIS
    Match Windows Disks to corresponding vHDD in VCenter

    .DESCRIPTION
    This script match Windows Disks to its corresponding vHDD in VCenter

    .PARAMETER vmName 
    Name of the VM
	
	.PARAMETER hostName 
    VM hostname (if different from vmName, or different domain to be specified)

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
    Version:        1.6
    Author:         Mark Southall

    .LINK
    https://github.com/MarkSouthall/PowershellScripts/blob/master/vHDDToWindowsDisk/vHDDToWindowsDisk.ps1 - adapted FMONs Script

    .PREREQUISITE
    - User for vCenter with appropriate rights
    - User for Get-WmiObject with appropriate rights
    - Current VMware Tools

#>

Param (
  [Parameter(Mandatory=$true, HelpMessage = 'Enter VM Name as displayed in vCenter')]
  [string]$vmName,
  [Parameter(Mandatory=$true, HelpMessage = 'Enter the VM hostname if different from VM Name, or different domain. Blank for same value.')]
  [AllowEmptyString()]
  [string]$hostName,
  [Parameter(Mandatory=$true, HelpMessage = 'Enter the vCenter hostname')]
  [string]$vCenter,
  [Parameter(Mandatory=$true, HelpMessage = 'Enter directory to output CSV file, blank for no output')]
  [AllowEmptyString()]
  [string]$outputDir
)

try{
	Write-Host "Attempting to import VMware.PowerCLI..."
	Import-Module -Name "VMware.PowerCLI" -ErrorAction Stop
}catch{
	Write-Host "PowerCLI module not found, attempting Vmware.VimAutomation.Core..."
	try{
		Add-PSSnapin "Vmware.VimAutomation.Core" -ErrorAction Stop
	}catch{
		Write-Host "Unable to load Powershell modules - please remove any existing PowerCLI installation, and run the following from an elevated Powershell prompt: Install-Module -Name VMware.PowerCLI -Force -AllowClobber"
		[void][System.Console]::ReadKey($true)
		Exit
	}
}

$cred = if ($cred){$cred}else{Get-Credential}  
Connect-VIServer -Server $vCenter -Credential $cred

## modification below here not necessary to run ##  
if(-not $hostName)
{
  $hostName = $vmName
}
  
#get windows disks via wmi  
$win32DiskDrive  = Get-WmiObject -Class Win32_DiskDrive -ComputerName $hostName -Credential $cred
  
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
  $partitions = Get-WmiObject -query "Associators of {Win32_DiskDrive.DeviceID=""$deviceID""} WHERE AssocClass = Win32_DiskDriveToDiskPartition" -ComputerName $hostName -Credential $cred
  foreach ($partition in $partitions)
  {
	$partitionID = $Partition.DeviceID
	$logicalDisk = Get-WmiObject -query "Associators of {Win32_DiskPartition.DeviceID=""$partitionID""} WHERE AssocClass = Win32_LogicalDiskToPartition" -ComputerName $hostName -Credential $cred
	
	#generate a result  
    $result = "" | select vmName,
							vmHardDiskDatastore,
							vmHardDiskVmdk,
							vmHardDiskName,
							vmDiskSize,
							winDiskSize,
							winLogicalDiskSize,
							driveLetter,
							driveName,
							scsiID
    $result.vmName = $vmName.toupper()  
    $result.vmHardDiskDatastore = $vmHardDisk.filename.split(']')[0].split('[')[1]  
    $result.vmHardDiskVmdk = $vmHardDisk.filename.split(']')[1].trim()  
    $result.vmHardDiskName = $vmHardDisk.Name  
	$result.vmDiskSize = $vmHardDisk.CapacityGB
	$result.winDiskSize = [decimal]::round($windowsDisk.Size/1gb)
	$result.winLogicalDiskSize = [decimal]::round($logicalDisk.Size/1gb)
	$result.driveLetter = $logicalDisk.Caption
	$result.driveName = $logicalDisk.VolumeName
    $result.scsiID = $scsiID
    $results += $result  
  }
}  
  
#sort and then output the results  
$results = $results | sort {[int]$_.vmHardDiskName.split(' ')[2]}  
if(-not $outputDir -eq "")
{
  $outputFile = "${vmName}_drive_matches.csv"
  $outputFilePath = Join-Path $outputDir $outputFile
  $results | export-csv -path $outputFilePath
}
$results | ft -AutoSize
Write-Host "Press any key to close"
[void][System.Console]::ReadKey($true)
Exit
