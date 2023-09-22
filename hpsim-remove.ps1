Param (
	[string]$SERVERNAME
)

#
if (-Not $SERVERNAME) {
	write-host "ARGUMENT ERROR - Requested SERVERNAME is empty."
	[Environment]::Exit(1)
}

$ExitCode = 0
if ($SERVERNAME -eq "01"){
	$ExitCode = 9
	Write-Host "FAILED - HPSIM Remove FAILED"
}
else{
	Write-Host "SUCCESSFUL - HPSIM Remove OK"
}

[Environment]::Exit($ExitCode)
