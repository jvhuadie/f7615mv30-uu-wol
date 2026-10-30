param([ValidateSet('EnableAutostart','DisableAutostart','ServiceStart','ServiceStop','Detect','Status','Install','Start','Stop','EnableService','Restore','Uninstall','UninstallFull')][string]$Action='Status',
 [string]$RouterAddress='192.168.1.1',[string]$Username='root',[Security.SecureString]$Password,
 [string]$BindingArchive='',[switch]$PidOnly)
$ErrorActionPreference='Stop';$session=$null;$ownsPassword=$false
. "$PSScriptRoot/tools/Network.ps1"
. "$PSScriptRoot/tools/Profiles.ps1"
if(!(Test-UuLanIPv4 $RouterAddress) -or $Username -notmatch '^[A-Za-z0-9_.-]{1,32}$'){throw '地址或用户名格式不正确'}
if(!$Password){$Password=Read-Host 'Telnet 密码（回车使用 Zte521）' -AsSecureString;$ownsPassword=$true;if($Password.Length -eq 0){$Password.Dispose();$Password=ConvertTo-SecureString 'Zte521' -AsPlainText -Force}}
if(!('ZteUuInstaller.TelnetSession' -as [type])){Add-Type -Path "$PSScriptRoot/tools/TelnetSession.cs"}
function Read-OntValue([string]$Command){
 $id=[Guid]::NewGuid().ToString('N');$begin='BEGIN_'+$id;$end='END_'+$id
 $session.SendLine("echo '$begin'; ( $Command ); rc=`$?; echo; echo '${end}:'`$rc")
 $r=$session.ReadUntil('(?m)^'+$end+':([0-9]+)\r*$',20000) -replace '\r+\n',"`n"
 $a=[regex]::Match($r,'(?m)^'+$begin+'\r?\n');$b=[regex]::Match($r,'(?m)^'+$end+':([0-9]+)\r*$')
 if(!$a.Success -or !$b.Success -or $b.Groups[1].Value -ne '0'){throw '只读识别未完成，未执行安装或管理操作。'}
 return $r.Substring($a.Index+$a.Length,$b.Index-$a.Index-$a.Length).Trim()
}
try{
 Write-Host '正在连接并只读识别型号、架构和固件……'
 $session=New-Object ZteUuInstaller.TelnetSession($RouterAddress,23,5000)
 $r=$session.ReadUntil('(?im)(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
 if($r -match '(?im)(?:login|username)\s*:\s*$'){
  $session.SendLine($Username);$null=$session.ReadUntil('(?im)password\s*:\s*$',15000);$session.SendSecureLine($Password)
  $r=$session.ReadUntil('(?im)access denied|login incorrect|(?:login|username)\s*:\s*$|(?:^|\n)[^\n]{0,100}[#$]\s*$',15000)
  if($r -match '(?im)access denied|login incorrect|(?:login|username)\s*:\s*$'){throw '登录失败，不会尝试其他密码。'}
 }
 if((Read-OntValue 'id -u') -cne '0'){throw '当前账户不是 root，未执行操作。'}
 $model=Read-OntValue 'uname -n';$arch=Read-OntValue 'uname -m'
 $fw=(Read-OntValue 'sha256sum /bin/cspd').Split(' ')[0];$boot=''
 if($model -ceq 'F7005MV3' -or $model -ceq 'skyworth'){$boot=(Read-OntValue 'sha256sum /etc/default/S01userconfig').Split(' ')[0]}
 $profile=Resolve-OntProfile $model $arch $fw $boot
 $route=@(Get-OntRoute $profile $Action $PidOnly.IsPresent $BindingArchive)
 $displayModel=if($profile -eq 'skd847n'){'SK-D847N'}else{$model}
 Write-Host ('已识别：'+$displayModel+' / '+$arch+'；固件匹配。')
 Write-Host ('安装方案：'+$(if($profile -eq 'f7615'){'F7615MV30 v0.6.1 / Wi-Fi 配置回调'}elseif($profile -eq 'g7615'){'G7615V2 / CU 框架'}elseif($profile -eq 'skd847n'){'创维 SK-D847N / 原厂 OSGi'}else{'F7005MV3 0.1.0-rc1 / 原厂插件机制'}))
 [pscustomobject]@{Kind='DetectedDevice';Model=$displayModel;Profile=$profile}
 $session.Dispose();$session=$null
 if($Action -eq 'Detect'){Write-Host '识别完成，未写入光猫文件、未启动或停止服务。';return}
 foreach($operation in $route){
  if($profile -eq 'f7615'){
   $global:LASTEXITCODE=0
   & "$PSScriptRoot/profiles/f7615/Auto.ps1" -RouterAddress $RouterAddress -Username $Username -Password $Password -Action $operation -NonInteractive
   if($LASTEXITCODE -ne 0){throw 'F7615 操作未完成；后续步骤已停止，请先检查状态。'}
  }elseif($profile -eq 'g7615'){
   & "$PSScriptRoot/profiles/g7615/Manage.ps1" -RouterAddress $RouterAddress -Username $Username -Password $Password -Action $operation
  }elseif($profile -eq 'skd847n'){
   & "$PSScriptRoot/profiles/skd847n/Manage.ps1" -RouterAddress $RouterAddress -Username $Username -Password $Password -Action $operation -BindingArchive $BindingArchive
  }else{
   & "$PSScriptRoot/profiles/f7005/Manage.ps1" -RouterAddress $RouterAddress -Username $Username -Password $Password -Action $operation -BindingArchive $BindingArchive -PidOnly:$PidOnly
  }
 }
}finally{if($session){$session.Dispose()};if($ownsPassword){$Password.Dispose()}}
