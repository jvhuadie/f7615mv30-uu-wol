# Exercise this app's own dialog without connecting to any modem.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:ink=[Drawing.Color]::FromArgb(23,44,60); $script:teal=[Drawing.Color]::Teal
$path=Join-Path $PSScriptRoot '../Gui.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
foreach($name in @('New-Label','New-Button','Show-UninstallChoice')) {
 $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $fn.Extent.Text
}
$script:form=New-Object Windows.Forms.Form
try {
 foreach($mode in @('cancel','retain','full')) {
  $script:mode=$mode; $script:failure=$null
  $timer=New-Object Windows.Forms.Timer; $timer.Interval=100
  $timer.Add_Tick({
   $dialog=@([Windows.Forms.Application]::OpenForms | Where-Object {$_.Text -eq '选择卸载方式'})[0]
   if(!$dialog){return}
   $timer.Stop()
   try {
    $radios=@($dialog.Controls | Where-Object {$_ -is [Windows.Forms.RadioButton]})
    $retain=@($radios | Where-Object {$_.Text -like '保留数据*'})[0]
    $full=@($radios | Where-Object {$_.Text -like '完全卸载*'})[0]
    $ack=@($dialog.Controls | Where-Object {$_ -is [Windows.Forms.CheckBox]})[0]
    $ok=@($dialog.Controls | Where-Object {$_.Text -eq '确认卸载'})[0]
    $cancel=@($dialog.Controls | Where-Object {$_.Text -eq '取消'})[0]
    if(!$retain.Checked -or $full.Checked -or $ack.Enabled -or $ack.Checked){throw 'Unsafe defaults'}
    if($dialog.AcceptButton -ne $cancel -or $dialog.CancelButton -ne $cancel){throw 'Keyboard default is unsafe'}
    switch($script:mode){
     cancel {$cancel.PerformClick()}
     retain {$ok.PerformClick()}
     full {
      $full.Checked=$true
      if(!$ack.Enabled -or $ok.Enabled){throw 'Full removal confirmation not required'}
      $ack.Checked=$true
      if(!$ok.Enabled){throw 'Full removal confirmation not accepted'}
      $ok.PerformClick()
     }
    }
   } catch {$script:failure=$_; $dialog.DialogResult=[Windows.Forms.DialogResult]::Cancel}
  })
  $timer.Start()
  try {
   $result=Show-UninstallChoice
   if($script:failure){throw $script:failure}
   $expected=@{cancel='';retain='Uninstall';full='UninstallFull'}[$mode]
   if($result -ne $expected){throw "Wrong action for $mode"}
  } finally {$timer.Dispose()}
 }
 Write-Output 'Dialog tests passed: default/cancel, retained removal, full removal with explicit acknowledgement.'
} finally {$script:form.Dispose()}
