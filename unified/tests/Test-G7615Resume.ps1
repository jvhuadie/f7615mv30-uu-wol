$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath("$PSScriptRoot/../profiles/g7615")
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Manage.ps1",[ref]$t,[ref]$e)
if($e.Count){throw $e[0]}
foreach($n in @('HashBytes','Resume-StagedPayload','Assert-Payload')){
 $fn=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n},$true)
 . ([scriptblock]::Create($fn.Extent.Text))
}
$framework='/proc/2750/root';$base="$framework/opt/uu-wol-g7615"
$payload=@{}
foreach($name in @('control.sh','service.sh','run.sh','uuplugin','xuplugin-guardian','managed-v1','uu.conf','payload.sha256')){$payload[$name]=[Text.Encoding]::ASCII.GetBytes("fixture-$name")}
$legacy=@{'control.sh'='5e9d4fe94d6bfb3332de7c82731b62082409b91974b2d126ee66112a813a457f';'run.sh'='977dcd4a45f0d2bdb3a676a7f3ad232af96c5ea581c6246abd4be9ae9ee3dd6a';'payload.sha256'='b70e1cd8af0682410b0537925e9fef7c539a3b9df948c3f1fe9303fedfaaed2d'}
function Upload($name,$bytes){$script:uploads.Add($name)}
function Remote($command){
 $script:commands.Add($command)
 if($script:mode -eq 'registered' -and $command.StartsWith('[ -d ')){throw 'registered service'}
 if($script:mode -eq 'unknown-file' -and $command.StartsWith('for f in ')){throw 'unknown file'}
 if($script:mode -eq 'running' -and $command.StartsWith('for f in /proc/')){throw 'UU running'}
 if($command -match "&& sha256sum '[^']+/([^/']+)'$"){
  $name=$Matches[1];$h=HashBytes $payload[$name]
  if($script:mode -ne 'current' -and $legacy.ContainsKey($name)){$h=$legacy[$name]}
  if($script:mode -eq 'corrupt' -and $name -eq 'xuplugin-guardian'){$h='0'*64}
  return [pscustomobject]@{Text="$h  $base/$name";Code=0}
 }
 if($script:mode -eq 'host-hash-fails' -and $command.Contains('sha256sum -c')){throw 'checksum mismatch'}
 return [pscustomobject]@{Text='';Code=0}
}
foreach($case in @('legacy','current','registered','unknown-file','running','corrupt')){
 $script:mode=$case;$script:uploads=New-Object 'Collections.Generic.List[string]';$script:commands=New-Object 'Collections.Generic.List[string]'
 $failed=$false;try{Resume-StagedPayload $payload 6>$null}catch{$failed=$true}
 if($case -in @('legacy','current')){
  if($failed){throw "Resume failed: $case"}
  $want=if($case -eq 'legacy'){'control.sh.repair,payload.sha256.repair,run.sh.repair'}else{''}
  if(($uploads -join ',') -cne $want){throw "Wrong uploads: $uploads"}
 }elseif(!$failed -or $uploads.Count){throw "Unsafe resume: $case"}
 if(($uploads -join ',') -match 'uuplugin|guardian'){throw 'Large binaries retransmitted'}
}
$script:mode='host-hash-fails';$failed=$false;try{Assert-Payload}catch{$failed=$true}
if(!$failed){throw 'Host checksum failure ignored'}
'RESUME_LEGACY_CURRENT_CORRUPT_FOREIGN_RUNNING_AND_HOST_HASH_GUARDS_OK'
