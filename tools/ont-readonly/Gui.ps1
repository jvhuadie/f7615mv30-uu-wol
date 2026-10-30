param([switch]$CheckOnly,[string]$PreviewImage='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:root=$PSScriptRoot;$script:work=$null;$script:resultDirectory=''
$script:form=New-Object Windows.Forms.Form
$script:form.Text='光猫 · 只读兼容性检测 v0.7.2'
$script:form.ClientSize=New-Object Drawing.Size(820,730)
$script:form.MinimumSize=New-Object Drawing.Size(840,770)
$script:form.StartPosition='CenterScreen'
$script:form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$script:form.BackColor=[Drawing.Color]::FromArgb(245,248,250)
function Label([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H){
 $c=New-Object Windows.Forms.Label;$c.Text=$Text;$c.SetBounds($X,$Y,$W,$H);$script:form.Controls.Add($c);return $c
}
function Input([string]$Text,[int]$X,[int]$Y,[int]$W){
 $c=New-Object Windows.Forms.TextBox;$c.Text=$Text;$c.SetBounds($X,$Y,$W,30);$script:form.Controls.Add($c);return $c
}
function Button([string]$Text,[int]$X,[int]$Y,[int]$W){
 $c=New-Object Windows.Forms.Button;$c.Text=$Text;$c.SetBounds($X,$Y,$W,38);$c.BackColor=[Drawing.Color]::White;$script:form.Controls.Add($c);return $c
}
$title=Label '光猫 · 只读适配检测' 24 20 760 38
$title.Font=New-Object Drawing.Font('Microsoft YaHei UI',18,[Drawing.FontStyle]::Bold)
$null=Label "多型号适配资料采集 · 不安装 UU、不上传脚本、不修改光猫、不重启服务。" 24 66 770 28
$null=Label '光猫 IP 地址' 24 111 115 25;$address=Input '192.168.1.1' 145 108 225
$null=Label 'Telnet 端口' 410 111 110 25;$port=New-Object Windows.Forms.NumericUpDown;$port.Minimum=1;$port.Maximum=65535;$port.Value=23;$port.SetBounds(535,108,110,30);$script:form.Controls.Add($port)
$null=Label 'Telnet 用户名' 24 155 120 25;$username=Input 'root' 145 152 225
$null=Label 'Telnet 密码' 410 155 115 25;$password=Input 'Zte521' 535 152 250;$password.UseSystemPasswordChar=$true
$null=Label '连接信息已预填，可按实际值修改。登录失败时不会尝试其他密码。' 145 192 640 26
$null=Label '标签型号（选填）' 24 237 125 25;$declaredModel=Input '' 155 234 215
$null=Label '硬件版本（选填）' 410 237 125 25;$declaredHardware=Input '' 545 234 240
$declaredModel.MaxLength=64;$declaredHardware.MaxLength=64
$null=Label '按机身标签填写，如 G7615V2、V2.0；与系统识别分别保留，请勿填写序列号。' 145 271 645 26
$null=Label '电脑保存目录' 24 307 120 25
$defaultOut=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ZTE-ONT-readonly'
$out=Input $defaultOut 145 304 520;$choose=Button '选择…' 679 300 106
$start=Button '开始只读检测' 24 356 170;$start.BackColor=[Drawing.Color]::FromArgb(8,127,130);$start.ForeColor=[Drawing.Color]::White
$open=Button '打开结果目录' 210 356 160;$open.Enabled=$false
$guide=Button '运行与发送说明' 386 356 170
$submit=Button '提交适配资料' 572 356 213
$status=Label '等待检测：电脑请连接这台光猫的局域网，确认已有 Telnet 权限。' 24 409 765 48
$log=New-Object Windows.Forms.TextBox;$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Vertical';$log.SetBounds(24,459,762,142);$log.Anchor='Top, Left, Right, Bottom';$log.BackColor=[Drawing.Color]::White;$script:form.Controls.Add($log)
$footer=Label "完成后先查看同名 TXT 顶部的设备摘要，检查内容后点击「提交适配资料」。`n上传 ZIP 原文件；网页「请输入您的名字」请填写机身标签上的设备型号。`n例如 F7005MV3、G7615V2；型号不明时填写「型号未知」。`n报告会隐藏常见地址及敏感字段；发送前请检查。本工具不自动上传结果。" 24 619 770 90
$footer.Anchor='Bottom, Left, Right'
$choose.Add_Click({$d=New-Object Windows.Forms.FolderBrowserDialog;try{$d.Description='选择电脑上的报告保存目录';if($d.ShowDialog($script:form)-eq 'OK'){$out.Text=$d.SelectedPath}}finally{$d.Dispose()}})
$guide.Add_Click({$null=[Windows.Forms.MessageBox]::Show($script:form,[IO.File]::ReadAllText((Join-Path $script:root 'INSTALL.txt')),'运行与发送说明')})
$open.Add_Click({if($script:resultDirectory -and [IO.Directory]::Exists($script:resultDirectory)){$null=[Diagnostics.Process]::Start($script:resultDirectory)}})
$submit.Add_Click({try{$null=[Diagnostics.Process]::Start('https://share.fnnas.net/s/a6cea4a86c714bdf87')}catch{$status.Text='无法打开浏览器，请从「运行与发送说明」复制资料收集链接。'}})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=150
function Set-Running([bool]$Busy){foreach($c in @($address,$username,$password,$port,$declaredModel,$declaredHardware,$out,$choose,$start)){$c.Enabled=!$Busy};$open.Enabled=!$Busy -and !!$script:resultDirectory}
$start.Add_Click({
 if($script:work){return}
 . (Join-Path $script:root 'tools/Network.ps1')
 if(!(Test-UuLanIPv4 $address.Text.Trim())){$status.Text='请填写有效的局域网 IPv4 地址。';return}
 if($username.Text.Trim() -notmatch '^[A-Za-z0-9_.-]{1,32}$' -or !$password.Text){$status.Text='请检查用户名和密码。';return}
 foreach($field in @($declaredModel,$declaredHardware)){if($field.Text.Trim() -notmatch '^$|^[A-Za-z0-9][A-Za-z0-9._()+ -]{0,63}$'){$status.Text='型号与硬件版本请使用英文字母、数字、空格或 . _ ( ) + -，最多 64 字。';return}}
 try{$save=[IO.Path]::GetFullPath($out.Text)}catch{$status.Text='请填写有效的电脑保存目录。';return}
 $secret=New-Object Security.SecureString;foreach($c in $password.Text.ToCharArray()){$secret.AppendChar($c)};$secret.MakeReadOnly()
 $runspace=[RunspaceFactory]::CreateRunspace();$runspace.ApartmentState='MTA';$ps=[PowerShell]::Create()
 try{
  $runspace.Open();$ps.Runspace=$runspace
  $null=$ps.AddCommand((Join-Path $script:root 'Collect.ps1')).AddParameter('RouterAddress',$address.Text.Trim()).AddParameter('Port',[int]$port.Value).AddParameter('Username',$username.Text.Trim()).AddParameter('Password',$secret).AddParameter('OutputDirectory',$save).AddParameter('DeclaredModel',$declaredModel.Text.Trim()).AddParameter('DeclaredHardware',$declaredHardware.Text.Trim())
  $async=$ps.BeginInvoke();$script:work=[PSCustomObject]@{PS=$ps;Runspace=$runspace;Async=$async;Secret=$secret;Seen=0}
  $log.Clear();$status.Text='正在检测，请保持连接；完成前不要关闭窗口。';Set-Running $true;$timer.Start()
 }catch{$secret.Dispose();$ps.Dispose();$runspace.Dispose();$status.Text='无法启动检测，请检查运行环境。'}
})
$timer.Add_Tick({
 if(!$script:work){return};$w=$script:work
 while($w.Seen -lt $w.PS.Streams.Information.Count){$log.AppendText([string]$w.PS.Streams.Information[$w.Seen].MessageData+"`r`n");$w.Seen++}
 if(!$w.Async.IsCompleted){return}
 $timer.Stop()
 try{
  $results=@($w.PS.EndInvoke($w.Async));$r=@($results | Where-Object {$_.Kind -eq 'ProbeResult'})
  if($w.PS.HadErrors -or $r.Count -ne 1){throw 'No report'}
  $script:resultDirectory=$r[0].Directory
  $status.Text=if($r[0].State -eq 'COMPLETE'){'检测完成。命令缺失或读取受限会记录在报告中；这不代表已经适配。'}else{'检测未完整完成，已保存失败或部分结果；请查看 TXT 后反馈。'}
  if($r[0].Identity.status -eq 'CONFLICT'){$status.Text='检测结果存在型号冲突，请核对机身标签；系统来源与用户填写信息已分别保存。'}
  elseif($r[0].Identity.model){$status.Text+=' 型号线索：'+$r[0].Identity.model+'（待核实）。'}
  $log.AppendText("`r`n"+$r[0].IdentitySummary+"`r`n")
  $log.AppendText("`r`n发送这个 ZIP：`r`n"+$r[0].Zip+"`r`n")
 }catch{$status.Text='未能完成或保存报告，请检查网络与保存目录；没有修改光猫。'}
 finally{$w.Secret.Dispose();$w.PS.Dispose();$w.Runspace.Dispose();$script:work=$null;Set-Running $false}
})
$script:form.Add_FormClosing({param($s,$e) if($script:work){$e.Cancel=$true;$status.Text='检测正在执行，请等待结束后再关闭窗口。'}})
if($PreviewImage){$script:form.Add_Shown({$b=New-Object Drawing.Bitmap($script:form.Width,$script:form.Height);try{$script:form.DrawToBitmap($b,(New-Object Drawing.Rectangle(0,0,$b.Width,$b.Height)));$b.Save($PreviewImage)}finally{$b.Dispose();$script:form.Close()}})}
try{$null=$script:form.ShowDialog()}finally{$timer.Dispose();$password.Text='';$script:form.Dispose()}
