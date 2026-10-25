$ErrorActionPreference='Stop'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../profiles/f7005/Manage.ps1",[ref]$t,[ref]$e)
if($e.Count){throw $e[0]}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-F7005InstallState'},$true)
Invoke-Expression $fn.Extent.Text
function Remote($cmd){if($script:sample -eq 'timeout'){throw 'Connection lost'};return [pscustomobject]@{Text=$script:sample}}
foreach($case in @(
 @('0:0:0:0:0:0:0','ABSENT'),@('1:1:1:1:1:1:1','PRESENT'),@('1:1:1:0:0:0:0','PRESENT'),
 @('1:0:0:0:0:0:0','INCOMPLETE'),@('0:0:1:0:0:0:0','INCOMPLETE'),@('1:1:2:0:0:0:0','INCOMPLETE'),
 @('0:0:0:1:0:0:0','INCOMPLETE'),@('0:0:0:0:1:0:0','INCOMPLETE'),@('0:0:0:0:0:1:0','INCOMPLETE'),@('0:0:0:0:0:0:1','INCOMPLETE'))){
 $script:sample=$case[0];if((Get-F7005InstallState) -ne $case[1]){throw "Unexpected classification $sample"}
}
foreach($value in @('','garbled','timeout','0:0:0:0:0:0:0 extra')){$script:sample=$value;$failed=$false;try{Get-F7005InstallState}catch{$failed=$true};if(!$failed){throw 'Unknown state accepted'}}
'INSTALL_STATE_ABSENT_PRESENT_INCOMPLETE_AND_ERRORS_OK'
