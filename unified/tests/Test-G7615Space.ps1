$ErrorActionPreference='Stop'
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../profiles/g7615/Manage.ps1",[ref]$t,[ref]$e)
if($e.Count){throw $e[0]}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CuFreeKiB'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
function Remote($command,[switch]$AllowFailure){
 if($command -eq 'cat /proc/mounts'){return [pscustomobject]@{Code=0;Text=$script:mounts}}
 if($command -ne 'df -k /opt/cu/apps'){throw "Wrong target: $command"}
 return [pscustomobject]@{Code=$script:code;Text=$script:disk}
}
$good='ubi0_0 /opt/cu/apps ubifs rw,nosuid,relatime 0 0'
$script:mounts=$good;$script:code=0
foreach($row in @('ubi0_0 88420 2564 81304 3% /opt/cu/apps',"ubi0_0`n 88420 2564 81304 3% /opt/cu/apps")){
 $script:disk="Filesystem 1024-blocks Used Available Use% Mounted on`n$row"
 if((Get-CuFreeKiB) -ne 81304){throw 'Capacity parse failed'}
}
foreach($case in @(
 @('ubi0_0 88420 80000 8420 91% /opt/cu/apps',0,$good,'空间不足'),
 @('ubi0_0 88420 72036 16384 81% /opt/cu/apps',0,$good,''),
 @('bad response',0,$good,'无法读取'),
 @('df: unsupported option',1,$good,'无法读取'),
 @('/dev/root 43776 39580 4196 90% /',0,$good,'无法读取'),
 @('ubi0_0 88420 2564 81304 3% /opt/cu/apps',0,$good.Replace('rw,','ro,'),'未确认'),
 @('ubi0_0 88420 2564 81304 3% /opt/cu/apps',0,'','未确认'),
 @('ubi0_0 88420 2564 999999 3% /opt/cu/apps',0,$good,'数据异常')
)){
 $script:disk=$case[0];$script:code=$case[1];$script:mounts=$case[2];$message=''
 try{$null=Get-CuFreeKiB}catch{$message=$_.Exception.Message}
 if($case[3]){if($message -notmatch $case[3]){throw "Wrong error: $message"}}elseif($message){throw $message}
}
'CU_SPACE_REAL_LAYOUT_WRAPPING_THRESHOLD_MOUNT_AND_FAILURE_CASES_OK'
