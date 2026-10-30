$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. "$root/tools/Profiles.ps1"
function Rejected($block){$failed=$false;try{& $block|Out-Null}catch{$failed=$true};if(!$failed){throw 'Unsafe input accepted'}}
$fw='4864d4dc6118f9aa5eed96f99538877c16742d10de43f78e66ee4aba7f4e1fa5'
$boot='6a84065579e08f5025cd2d56b93a3d7b511dc79ab93fceec9fd1913a17c3c211'
if((Resolve-OntProfile skyworth aarch64 $fw $boot) -cne 'skd847n'){throw 'Skyworth profile'}
Rejected {Resolve-OntProfile skyworth aarch64 ('0'*64) $boot}
Rejected {Resolve-OntProfile skyworth aarch64 $fw ('0'*64)}
Rejected {Resolve-OntProfile skyworth armv7l $fw $boot}
Rejected {Resolve-OntProfile SK-D847N aarch64 $fw $boot}
Rejected {Get-OntRoute skd847n Install $true ''}
Rejected {Get-OntRoute skd847n EnableService $false ''}
Rejected {Get-OntRoute skd847n Stop $false 'binding.json'}
if((@(Get-OntRoute skd847n DisableAutostart $false '') -join ',') -cne 'Stop'){throw 'Coupled startup'}
if((@(Get-OntRoute skd847n Install $false 'binding.json') -join ',') -cne 'Install'){throw 'Binding route'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile("$root/profiles/skd847n/Manage.ps1",[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
foreach($name in @('Read-BindingArchive','Try-LanUpload')){
 $fn=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name},$true)
 . ([scriptblock]::Create($fn.Extent.Text))
}
function Remote {throw 'Private binding must not use an HTTP server'}
$bytes=New-Object byte[] 2048
if((Try-LanUpload '.sn.restore' $bytes '/unused') -ne $false){throw 'Private binding used HTTP'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SK-BindingTest-'+[Guid]::NewGuid().ToString('N')+'.json')
try{
 @{Model='SK-D847N';Format='SK_BINDING_V1';Files=@{'.sn'=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('synthetic'))}}|ConvertTo-Json -Depth 4|Set-Content $temp -Encoding UTF8
 $parsed=Read-BindingArchive $temp
 if([Text.Encoding]::ASCII.GetString($parsed['.sn']) -cne 'synthetic'){throw 'Binding content lost'}
 foreach($record in @(
  @{Model='Other';Format='SK_BINDING_V1';Files=@{}},
  @{Model='SK-D847N';Format='SK_BINDING_V1';Files=@{'../outside'='YQ=='}},
  @{Model='SK-D847N';Format='SK_BINDING_V1';Files=@{'uu.conf'='invalid-base64'}}
 )){
  $record|ConvertTo-Json -Depth 4|Set-Content $temp -Encoding UTF8
  Rejected {Read-BindingArchive $temp}
 }
}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
'SK_PROFILE_NEGATIVE_ROUTING_BINDING_VALIDATION_AND_PRIVATE_TRANSFER_OK'
