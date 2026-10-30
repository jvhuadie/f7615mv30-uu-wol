function Resolve-OntProfile([string]$Model,[string]$Architecture,[string]$Firmware,[string]$BootScript){
 if($Architecture -cne 'aarch64'){throw 'CPU 架构不在已验证范围内，未执行安装或管理操作。'}
 switch -CaseSensitive ($Model){
  'skyworth' {if($Firmware -cne '4864d4dc6118f9aa5eed96f99538877c16742d10de43f78e66ee4aba7f4e1fa5' -or $BootScript -cne '6a84065579e08f5025cd2d56b93a3d7b511dc79ab93fceec9fd1913a17c3c211'){throw '创维型号或固件未匹配，不执行操作'};return 'skd847n'}
  'G7615V2' {if($Firmware -cne '0afb71c8d938a82395675bc1fa96cb10ec23f5a9ab9f4f3d66073257d02c7b36'){throw 'G7615V2 固件指纹不匹配，未执行操作。'};return 'g7615'}
  'F7615MV30' {if($Firmware -cne '58a5a48a3bfb5bd38209ffa58e3fb5b635623d4a2125799cd8e7e897e3a6a58f'){throw 'F7615MV30 固件指纹不匹配，未执行操作。'};return 'f7615'}
  'F7005MV3' {if($Firmware -cne '453c47535b274071a5ae83d533d825e5072c8b562857e51eeefa8826953180ed' -or $BootScript -cne '7c4cc96aaaafc766d1d0b558672487b3532eae3b2df11111a51160a071455f21'){throw 'F7005MV3 固件或启动脚本指纹不匹配，未执行操作。'};return 'f7005'}
  default {throw ('型号 '+$Model+' 尚未适配，未执行安装或管理操作。')}
 }
}
function Get-OntRoute([string]$Profile,[string]$Action,[bool]$PidOnly,[string]$BindingArchive){
 if($Profile -notin @('f7615','f7005','g7615','skd847n')){throw '未知安装方案'}
 if($Profile -eq 'skd847n'){
  if($PidOnly -or $Action -eq 'EnableService' -or ($BindingArchive -and $Action -ne 'Install')){throw '创维仅支持安装时恢复 JSON 绑定备份，不支持 F7005 PID 选项'}
  switch($Action){
   'Detect' {return @()}
   {$_ -in @('ServiceStart','EnableAutostart')} {return @('Start')}
   {$_ -in @('ServiceStop','DisableAutostart')} {return @('Stop')}
   {$_ -in @('Status','Install','Start','Stop','Restore','Uninstall','UninstallFull')} {return @($Action)}
   default {throw '此操作不受支持'}
  }
 }
 if($Profile -eq 'g7615'){
  if($PidOnly -or $BindingArchive -or $Action -eq 'EnableService'){throw 'G7615 不支持 F7005 专用选项'}
  switch($Action){
   'Detect' {return @()}
   'ServiceStart' {return @('Start')}
   'ServiceStop' {return @('Stop')}
   {$_ -in @('Status','Install','Start','Stop','EnableAutostart','DisableAutostart','Restore','Uninstall','UninstallFull')} {return @($Action)}
   default {throw '此操作不受支持'}
  }
 }
 if($Profile -eq 'f7615' -and ($PidOnly -or $BindingArchive)){throw 'PID 测试和 TGZ 恢复仅用于 F7005MV3，请取消这些选项。'}
 if($Profile -eq 'f7005' -and $Action -eq 'Restore'){throw 'F7005MV3 请通过安装时选择绑定备份恢复。'}
 if($Profile -eq 'f7615' -and $Action -eq 'EnableService'){throw 'PID 模式切换仅用于 F7005MV3。'}
 if($Action -eq 'Detect'){return @()}
 if($Action -in @('EnableAutostart','DisableAutostart','ServiceStart','ServiceStop')){
  if($Profile -eq 'f7615'){
   if($Action -eq 'ServiceStart'){return @('Start')};if($Action -eq 'ServiceStop'){return @('Stop')};return @($Action)
  }
  if($Action -in @('EnableAutostart','ServiceStart')){return @('Start')};return @('Stop')
 }
 if($Profile -eq 'f7615'){
  switch($Action){
   'Status' {return @('Check')}
   'Start' {return @('Start','EnableAutostart')}
   'Stop' {return @('DisableAutostart','Stop')}
   {$_ -in @('Install','Uninstall','UninstallFull','Restore')} {return @($Action)}
   default {throw '此操作不受支持'}
  }
 }
 if($Action -notin @('Status','Install','Start','Stop','EnableService','Uninstall','UninstallFull')){throw '此操作不受支持'}
 return @($Action)
}
