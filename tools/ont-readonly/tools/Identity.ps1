function Get-ProbeIdentity($Sections,[string]$DeclaredModel='',[string]$DeclaredHardware='') {
    $candidates=New-Object Collections.Generic.List[object]
    $architecture='';$software='';$hardware='';$fingerprint=''
    foreach($section in $Sections){
        if($section.id -eq 'identity-fields'){
            foreach($line in ($section.output -split "`n")){
                if($line -match '^HOSTNAME=(F[0-9][A-Za-z0-9_.-]{1,40}|G[0-9][A-Za-z0-9_.-]{1,40})\s*$'){
                    $candidates.Add([pscustomobject]@{value=$Matches[1].ToUpperInvariant();source='uname -n（系统主机名）'})
                }
                elseif($line -match '^ARCH=([A-Za-z0-9_-]{1,32})\s*$'){$architecture=$Matches[1]}
                elseif($line -match '^SOFTWARE_VERSION=([A-Za-z0-9][A-Za-z0-9._()+ -]{0,95})\s*$'){$software=$Matches[1].Trim()}
            }
        }
        if($section.id -eq 'model'){
            # Device-tree strings often describe a board/SoC. Only explicit ZTE-style model tokens count.
            $match=[regex]::Match($section.output,'(?im)^FILE /proc/device-tree/model\r?\n([^\r\n]+)')
            if($match.Success){
                foreach($m in [regex]::Matches($match.Groups[1].Value,'(?i)(?<![A-Za-z0-9])(F[0-9][A-Za-z0-9_.-]{1,40}|G[0-9][A-Za-z0-9_.-]{1,40})(?![A-Za-z0-9])')){
                    $candidates.Add([pscustomobject]@{value=$m.Value.ToUpperInvariant();source='/proc/device-tree/model'})
                }
            }
            if(!$software){$m=[regex]::Match($section.output,'(?m)^VERSION(?:_ID)?=["'']?([A-Za-z0-9][A-Za-z0-9._()+ -]{0,95})["'']?\s*$');if($m.Success){$software=$m.Groups[1].Value.Trim()}}
        }
        if($section.id -eq 'hooks'){$m=[regex]::Match($section.output,'(?im)^([0-9a-f]{64})\s+/bin/cspd\s*$');if($m.Success){$fingerprint=$m.Groups[1].Value.ToLowerInvariant()}}
    }
    $models=@($candidates | ForEach-Object {$_.value} | Select-Object -Unique)
    $model=if($models.Count -eq 1){$models[0]}else{''}
    $status=if($models.Count -gt 1){'CONFLICT'}elseif($model){'CANDIDATE'}else{'UNKNOWN'}
    if($DeclaredModel -and $models.Count -gt 0 -and @($models | Where-Object {$_ -ine $DeclaredModel}).Count -gt 0){$status='CONFLICT'}
    $label=if($status -eq 'CONFLICT'){'型号冲突'}elseif($model){$model}elseif($DeclaredModel){'用户填写-'+$DeclaredModel}else{'型号未知'}
    return [pscustomobject]@{model=$model;status=$status;candidates=@($candidates.ToArray());architecture=$architecture;softwareVersion=$software;hardwareVersion=$hardware;firmwareFingerprint=$fingerprint;declaredModel=$DeclaredModel;declaredHardwareVersion=$DeclaredHardware;fileLabel=$label}
}
function Format-ProbeIdentity($Identity){
    $state=switch($Identity.status){'CONFLICT'{'存在冲突，请核对机身标签'};'CANDIDATE'{'待核实（系统线索）'};default{'未识别'}}
    $lines=New-Object Collections.Generic.List[string]
    $lines.Add('设备型号：'+$(if($Identity.model){$Identity.model}else{'未确认'}))
    $lines.Add('识别状态：'+$state)
    foreach($candidate in $Identity.candidates){$lines.Add('型号线索：'+$candidate.value+'；来源：'+$candidate.source)}
    $lines.Add('用户填写型号：'+$(if($Identity.declaredModel){$Identity.declaredModel}else{'未填写'}))
    $lines.Add('用户填写硬件版本：'+$(if($Identity.declaredHardwareVersion){$Identity.declaredHardwareVersion}else{'未填写'}))
    $lines.Add('CPU 架构：'+$(if($Identity.architecture){$Identity.architecture}else{'未获取'}))
    $lines.Add('软件版本：'+$(if($Identity.softwareVersion){$Identity.softwareVersion}else{'未获取'}))
    $lines.Add('固件指纹（/bin/cspd SHA-256）：'+$(if($Identity.firmwareFingerprint){$Identity.firmwareFingerprint}else{'未获取'}))
    return [string]::Join("`r`n",$lines)
}
