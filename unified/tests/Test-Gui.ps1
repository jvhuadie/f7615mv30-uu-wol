$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Gui.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'GUI syntax'}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-Message'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$script:cards=@{};foreach($key in @('model','version','service','boot','cloud','log')){$script:cards[$key]=New-Object Windows.Forms.Label}
$script:log=New-Object Windows.Forms.TextBox;$script:log.Multiline=$true;$script:tips=New-Object Windows.Forms.ToolTip
try{
 Add-Message '已识别：F7005MV3 / aarch64；固件匹配。'
 Add-Message "VERSION=0.1.0-rc1`nPERSISTENT_STATE=32`nstate=RUNNING`nPROCESS=123 /usr/plugin/bundlecache/bundle24/data/uuplugin`ntcp 0 0 10.0.0.2:333 106.2.95.36:16000 ESTABLISHED 123/uuplugin"
 if($cards.model.Text -ne 'F7005MV3' -or $cards.service.Text -ne '运行中' -or $cards.boot.Text -ne '已启用' -or $cards.cloud.Text -ne '已建立'){throw 'F7005 status cards'}
 Add-Message "VERSION=0.1.0-rc1`nPERSISTENT_STATE=2`nstate=RUNNING"
 if($cards.service.Text -eq '运行中' -or $cards.cloud.Text -eq '已建立'){throw 'Stale state reported healthy'}
 Add-Message '已识别：F7615MV30 / aarch64；固件匹配。'
 Add-Message '光猫端版本：0.3';Add-Message '服务：运行中';Add-Message '自启：已启用';Add-Message 'UU 云连接：已建立'
 if($cards.model.Text -ne 'F7615MV30' -or $cards.version.Text -ne 'v0.3' -or $cards.service.Text -ne '运行中'){throw 'F7615 status cards'}
 Add-Message '光猫端版本：未安装';Add-Message '服务：未安装';Add-Message '自启：未安装';Add-Message 'UU 云连接：未连接';Add-Message '日志管道：未安装'
 foreach($key in @('version','service','boot','log')){if($cards[$key].Text -ne '未安装'){throw "Absent card not reset: $key"}}
 if($cards.cloud.Text -ne '未连接'){throw 'Absent cloud card'}
 Add-Message '已识别：G7615V2 / aarch64；固件匹配。'
 Add-Message "VERSION=0.1.0-rc1`nstate=RUNNING`nPROCESS=123 /opt/uu-wol-g7615/uuplugin`nAUTOSTART=ENABLED`nCLOUD=UNVERIFIED`nLOG=procd-logread"
 if($cards.model.Text -ne 'G7615V2' -or $cards.boot.Text -ne '已启用' -or $cards.cloud.Text -ne '待 UU App 验证' -or $cards.log.Text -ne 'CU 框架日志'){throw 'G7615 cards'}
 Add-Message "AUTOSTART=DISABLED`nstate=UNINSTALLED"
 if($cards.boot.Text -ne '未启用' -or $cards.service.Text -ne '已卸载（保留绑定）'){throw 'G7615 removal cards'}
 Add-Message '已识别：SK-D847N / aarch64；固件匹配。'
 Add-Message "VERSION=0.1.0-rc1`nPERSISTENT_STATE=32`nREBOOT_ACCEPTANCE=PASSED`nPROCESS=233 /usr/data/uu-wol-skd847n/uuplugin`nCLOUD_TCP_ESTABLISHED=yes"
 if($cards.model.Text -ne 'SK-D847N' -or $cards.boot.Text -ne '本次重启已验证' -or $cards.cloud.Text -ne 'TCP 已连接'){throw 'Skyworth status cards'}
 Add-Message "MAIN_RUNNING=no`nCLOUD_TCP_ESTABLISHED=no"
 if($cards.service.Text -eq '运行中' -or $cards.cloud.Text -eq 'TCP 已连接'){throw 'Skyworth stale process state'}
 Write-Output 'BOTH_MODEL_CARDS_STALE_STATE_AND_UNINSTALLED_TESTS_OK'
}finally{$log.Dispose();$tips.Dispose();foreach($c in $cards.Values){$c.Dispose()}}
. "$root/tools/GuiWorker.ps1"
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('OntGuiTest-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $sandbox
try{
 foreach($fail in @($false,$true)){
  $body=if($fail){"throw 'EXPECTED_WORKER_FAILURE'"}else{"Write-Host '服务：运行中'"}
  [IO.File]::WriteAllText((Join-Path $sandbox 'Manage.ps1'),'param($RouterAddress,$Username,$Password,$Action,$BindingArchive,[switch]$PidOnly) '+$body,(New-Object Text.UTF8Encoding($true)))
  $secret=ConvertTo-SecureString 'fixture' -AsPlainText -Force
  $w=Start-UuGuiWorker -ToolRoot $sandbox -Address '192.168.2.1' -Port 23 -Username root -Password $secret -ReadOnly $true -Action Check
  if(!$w.Async.AsyncWaitHandle.WaitOne(10000)){throw 'Worker timeout'}
  $r=Complete-UuGuiWorker $w
  if($r.Success -eq $fail){throw 'Worker completion incorrect'}
  if($fail -and ($r.Messages -join '') -notmatch 'EXPECTED_WORKER_FAILURE'){throw 'Worker error hidden'}
 }
 Write-Output 'GUI_WORKER_SUCCESS_AND_FAILURE_TESTS_OK'
}finally{
 $full=[IO.Path]::GetFullPath($sandbox);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
 if([IO.Path]::GetDirectoryName($full) -eq $temp -and [IO.Path]::GetFileName($full).StartsWith('OntGuiTest-')){Remove-Item -LiteralPath $full -Recurse -Force}
}
