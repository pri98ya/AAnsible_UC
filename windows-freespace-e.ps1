Param (
	[string]$SQLINSTANCEPORTSET,
	[string]$DISKFREESPACETHRESHOLDPC,
	[string]$DBFREEPC,
	[string]$STRANGEDISKPC,
	[string]$STRANGEDBPC
)

#
$DiskId = "E:"
$DiskFreePcThreshold = 10
$DbfFreePcThreshold = 20
$StrangeDiskFreePc = 10
$StrangeDbFreePc = 85
$ExitCode = 0

#
if ($DISKFREESPACETHRESHOLDPC) {
	try {
	    $DiskFreePcThreshold = [int] $DISKFREESPACETHRESHOLDPC
	}
	catch {
		write-host "FAILED_ARGUMENT_ERROR DISKFREESPACETHRESHOLDPC non numeric value"
		[Environment]::Exit(1)
	}
}

if ($DBFREEPC) {
	try {
	    $DbfFreePcThreshold = [int] $DBFREEPC
	}
	catch {}
}

if ($STRANGEDISKPC) {
	try {
		$StrangeDiskFreePc = [int] $STRANGEDISKPC
	}
	catch {}
}

if ($STRANGEDBPC) {
	try {
	    $StrangeDbFreePc = [int] $STRANGEDBPC
	}
	catch {}
}

# Input Args control - Disk free space Threshold is mandatory and must be numeric
if ( $DiskFreePcThreshold -gt 100 ){
	write-host "FAILED_ARGUMENT_ERROR DISKFREESPACETHRESHOLDPC bad value"
	[Environment]::Exit(2)
}
# Check disk and Get Current spaces
$myLogicalDisk = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $DiskId }
if (-Not $myLogicalDisk) {
	Write-Host "Unable to get disk $DiskId"
	[Environment]::Exit(3)
}
$DiskFreePc = [int] (( $myLogicalDisk.FreeSpace / $myLogicalDisk.size) * 100)
if ($DiskFreePc -gt $DiskFreePcThreshold){
	Write-Host "CLOSED COMPLETE - Ticket to close - $DiskId Disk Free Space Percentage is $DiskFreePc %. "
	[Environment]::Exit(0)
}

$Enrich = "$DiskId Disk Free Space Percentage is $DiskFreePc%."

# Compute Size to add to have 50% free in the disk : ToAdd = Tot - (2*Free)
$toAdd = $myLogicalDisk.size - (2 * $myLogicalDisk.FreeSpace )
if ($toAdd -gt 0){
    $Enrich = $Enrich + [String]::Format(" To have 50% Free Space, need to add {0}GB. ", [int] ($toAdd / 1GB) )
}

# SQL Server Analysis Part
if (-Not $SQLINSTANCEPORTSET) {
	$str = "CLOSED INCOMPLETE - Need further investigation - " + $Enrich + "No SQL Server Instance to check. "
	Write-Host $str
	[Environment]::Exit(0)
}

#
$SqlInstanceList = New-Object Collections.Generic.List[String]
try {
	$SqlInstanceList = $SQLINSTANCEPORTSET -split ";"
}
catch {
	Write-Host "EXCEPTION SQL Server Instance and/or SQL Server Port set values are not correct."
	[Environment]::Exit(4)
}

# 
if (-Not $SqlInstanceList){
	$str = "CLOSED INCOMPLETE - Need further investigation - " + $Enrich + "No SQL Server Instance to check. "
	Write-Host $str
	[Environment]::Exit(0)
}

# Work foreach instance
$InfoComp = ""
$ExitCode = 0
$EmergengyChangeToCreate = $false

foreach ($SQLINSTANCEPORT in $SqlInstanceList){

	$InfoInstance = ""
	$SQLINSTANCE =  ""
	$SQLPORT = ""
	try {
		if ($SQLINSTANCEPORT -match '^(?<servername>[\w-\.]+)#(?<instance>[\w-\.]+)#(?<port>\d+)$') {
			$SQLINSTANCE = $Matches.instance
			$SQLPORT = $Matches.port
		}
	}
	catch {
		Write-Host "EXCEPTION SQL Server Instance and/or SQL Server Port values are not correct."
		$ExitCode = 5
		[Environment]::Exit($ExitCode)
	}
	if (-Not $SQLINSTANCE -OR -Not $SQLPORT) {
		continue
	}

	if ($InfoComp){
		$InfoComp = $InfoComp + "INSTANCE " + $SQLINSTANCE
	}
	else {
		$InfoComp = "INSTANCE " + $SQLINSTANCE
	}
	
	# Get Database list from SQL Server
	try {
		$DbRows = Invoke-Sqlcmd -ServerInstance "localhost\$SQLINSTANCE,$SQLPORT" -Database "master" -Query "SELECT * FROM sys.databases WHERE Lower(name) not in ('master','tempdb','model','msdb','reportserver','reportservertempdb','ssisdb') ORDER BY database_id"
		
		# Working on all databases of the current instance
		if (-Not $DbRows){
			$InfoComp = $InfoComp + "/No User Database found. "
		}
		else {
		
			foreach ($db in $DbRows){
			
				$SQLDBNAME = $db.name
				$InfoComp = $InfoComp + "/Database " + $SQLDBNAME + ": "
				
				try {
					# SQLServer Sys.sysfiles table query
					$SysFileRows = Invoke-Sqlcmd -ServerInstance "localhost\$SQLINSTANCE,$SQLPORT" -Database $SQLDBNAME -Query "SELECT size , maxsize , filename FROM sys.sysfiles where filename LIKE '$DiskId%' "
					if (-Not $SysFileRows){
						$InfoComp = $InfoComp + "No Sys files on this disk. "
						continue
					}
					
					#
					$TotDbMaxSize = 0
					$TotDbFreeSize = 0
					$TotDbFreePc = 0
					$strDatafiles = ""
					$strStrange = ""
					foreach ($row in $SysFileRows){
						$iMaxSize = $row.maxsize
						if ($iMaxSize -lt 0){
							# no sqlserver limit, max size -> dbf length + disk free space
							if (!(Test-Path $row.filename)){
								continue
							}
							$f = Get-Item $row.filename
							$iMaxSize = $f.length + $myLogicalDisk.FreeSpace
						}
						$iFreeSize = $iMaxSize - $row.size
						$iDbfFreePc =  [int] (($iFreeSize / $iMaxSize) * 100)
						$strfilename = $row.filename.Replace('\','/')
						
						if ($iDbfFreePc -le $DbfFreePcThreshold){
							$strDatafiles = $strDatafiles + [String]::Format("{0} - Size {1} KB - Max {2} KB - Free {3}%. ", $strfilename, [int]($row.size / 1KB), [int]($iMaxsize / 1KB) , $iDbfFreePc)
						}
						$TotDbMaxSize = $TotDbMaxSize + $iMaxSize
						$TotDbFreeSize = $TotDbFreeSize + $iFreeSize
					}

					if ($TotDbMaxSize -gt 0) {
						$TotDbFreePc = [int] (($TotDbFreeSize / $TotDbMaxSize) * 100)
						
						# if DiskFree is low and dbfile free sizes are high, then there is something strange so need further investigation
						if ( ($DiskFreePc -le $StrangeDiskFreePc) -AND ($TotDbFreePc -ge $StrangeDbFreePc) ) {
							$strStrange = [String]::Format("Something STRANGE, Free disk space is Low and db available free space is High. Disk Free Space {0}% - DB Free space {1}%. ", $DiskFreePc , $TotDbFreePc)
							$InfoComp = $InfoComp + $strStrange
						}
					}

					if ($strDatafiles){	
						$InfoComp = $InfoComp + "Datafile Low Free space :" + $strDatafiles + " (Emergency change should be created to solve). "
						$EmergengyChangeToCreate = $true
					}
					else {
						$InfoComp = $InfoComp + "Datafile sizes are all OK. "
					}
				}
				catch{}
				
			} # End foreach Database
		}
	}
	catch {}
	
} # End of foreach Instance

	
if ($EmergengyChangeToCreate){
	Write-Host "CLOSED COMPLETE - Need further investigation - An emergency change should be created becaue of existing datafile with low free space in SQL Server - $Enrich - $InfoComp"
}
else {
	Write-Host "CLOSED COMPLETE - Need further investigation - $Enrich - $InfoComp"
}

[Environment]::Exit(0)
