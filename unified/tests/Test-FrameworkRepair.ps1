param([string]$OriginalJar='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath("$PSScriptRoot/../profiles/f7005")
. "$root/tools/FrameworkRepair.ps1"
function HashBytes([byte[]]$b){$s=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($s.ComputeHash($b)).Replace('-','').ToLowerInvariant()}finally{$s.Dispose()}}
function Start-Sleep {param($Seconds)}
function Remote($command,[switch]$AllowFailure){
 if($command.StartsWith('count=0;')){
  $script:stateReads++
  $h=if($script:mode -like 'fixed*'){$script:AndlinkFixed}elseif($script:mode -eq 'unknown'){'0'*64}elseif($script:mode -eq 'changed' -and $script:stateReads -gt 1){$script:AndlinkFixed}else{$script:AndlinkOriginal}
  return [pscustomobject]@{Text=($h+'  /usr/plugin/bundlecache/bundle13/version0.0/bundle.jar');Code=0}
 }
 if($command.StartsWith('pid=;')){
  $script:samples++
  if($script:mode -eq 'transport'){throw 'Telnet timeout'}
  $code=if($script:mode -in @('unhealthy','fixed-unhealthy','check-unhealthy')){1}elseif($script:mode -eq 'command-error'){2}else{0}
  $sample=if($script:mode -eq 'malformed'){'unexpected text'}elseif($script:mode -eq 'restart' -and $script:samples -gt 1){'2564:9999'}else{'2553:6866'}
  return [pscustomobject]@{Text=$sample;Code=$code}
 }
 if($command.StartsWith('echo ''7c4')){return [pscustomobject]@{Text='OK';Code=0}}
 $script:mutations++;throw 'Unexpected remote mutation'
}
function Snapshot {$script:backups++;throw 'Simulated backup failure'}
foreach($case in @('fixed','original','unhealthy','restart','fixed-unhealthy','unknown','transport','command-error','malformed','changed','check-unhealthy')){
 $script:mode=$case;$script:mutations=0;$script:backups=0;$script:stateReads=0;$script:samples=0;$failed=$false
 try{Ensure-F7005Framework -CheckOnly:($case -eq 'check-unhealthy')}catch{$failed=$true}
 if($failed -ne ($case -notin @('fixed','original'))){throw "Wrong result: $case"}
 if($script:mutations -ne 0){throw "Unexpected write: $case"}
 $wantBackups=if($case -in @('unhealthy','restart')){1}else{0}
 if($script:backups -ne $wantBackups){throw "Wrong repair decision: $case"}
 if($case -in @('original','fixed') -and $script:samples -ne 4){throw 'Healthy branch skipped observation'}
}
if($OriginalJar){
 $bytes=[IO.File]::ReadAllBytes($OriginalJar);$result=New-AndlinkPatchedBytes $bytes
 if((HashBytes $result) -ne $script:AndlinkFixed){throw 'Delta reconstruction failed'}
 $bytes[0]=$bytes[0] -bxor 1;$failed=$false
 try{$null=New-AndlinkPatchedBytes $bytes}catch{$failed=$true}
 if(!$failed){throw 'Modified original accepted'}
}
Write-Output 'HEALTHY_ORIGINAL_SKIP_UNHEALTHY_REPAIR_TRANSPORT_ABORT_CHECKONLY_AND_DELTA_OK'
