$ErrorActionPreference='Stop'
$source=Get-Content "$PSScriptRoot/../profiles/f7005/Manage.ps1" -Raw
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'RemoveProjectConfig'},$true)
Invoke-Expression $fn.Extent.Text
$path='/usr/plugin/bundlecache/bundle5/data/config/local/ont/uuwol/f7005/SetMsgConfig.config'
$hash='a'*64
function Remote($cmd){
 if($cmd.StartsWith('[ ! -e')){
  $script:probes++
  if($script:mode -eq 'guard'){throw 'guard rejected'}
  $value=if($script:mode -eq 'empty' -or $script:probes -gt 2){''}elseif($script:mode -eq 'invalid'){'unexpected path'}elseif($script:mode -eq 'changed' -and $script:probes -eq 2){('b'*64)+'  '+$path}else{$hash+'  '+$path}
  return [pscustomobject]@{Text=$value}
 }
 if(!$script:backed){throw 'Deletion before verified backup'}
 if($cmd -notmatch 'sha256sum -c' -or $cmd -match 'rm -r|andlink'){throw 'Unsafe cleanup command'}
 $script:deletes++;return [pscustomobject]@{Text=''}
}
function Snapshot($kind,$args){
 if($script:mode -eq 'backup-fail'){throw 'backup failure'}
 $script:backed=$true
}
foreach($case in @('empty','normal','changed','invalid','backup-fail','guard')){
 $script:mode=$case;$script:probes=0;$script:deletes=0;$script:backed=$false;$failed=$false
 try{RemoveProjectConfig}catch{$failed=$true}
 $wantFail=$case -notin @('empty','normal')
 if($failed -ne $wantFail){throw "Unexpected result: $case"}
 if($script:deletes -ne $(if($case -eq 'normal'){1}else{0})){throw "Unexpected deletion: $case"}
}
Write-Output 'CONFIG_CLEANUP_BACKUP_AND_REJECTION_TESTS_OK'
