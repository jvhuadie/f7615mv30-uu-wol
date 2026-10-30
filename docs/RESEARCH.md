# 实现与维护说明

## 各型号的启动机制

F7615MV30 使用已验证固件的 `/wlan/wifi_debug.sh` 无线配置回调。回调等待后调用项目控制脚本；参考设备的重启探针曾确认该入口以 root 执行。它并非通用的 rc.local，不能推广至无无线功能或其他固件。全新安装后需手动重启。

F7005MV3 使用原厂 OSGi 插件生命周期。UU 以普通插件用户运行，仅授予 CAP_NET_RAW；固定用途的 PID 准备程序仅授予 CAP_DAC_OVERRIDE，只创建或校验专用 PID 文件后退出。两份自有程序的 immutable 保护用于防止原厂开机 chown 清除 capability，工具卸载时先解除保护。

F7005 安装时核对 Andlink 已知版本并检查健康状态：原始版本健康则跳过，明确异常才备份修复，已修复版本只检查健康。未知版本和通信异常停止操作。故障分支完整实机验证仍未完成，不能仅凭模拟测试认定所有设备可用。

G7615V2 使用 CU/procd 框架，服务启停与自启独立；大文件优先局域网 HTTP 传输，失败回退 Telnet，始终核对摘要。

创维 SK-D847N 使用原厂 OSGi，固定辅助程序在校验后降为 UID 107，仅保留 CAP_NET_RAW。JFFS2 不支持文件 capability，因此不套用 F7005 方案。权限实现及验收边界见[创维说明](SK-D847N.md)。

## 固件与程序校验

型号、架构和固件指纹由 `unified/tools/Profiles.ps1` 统一判断。F7005 额外校验启动脚本；运行资源及修复差分使用固定哈希校验。更改校验值前必须重新完成对应设备验证，不因型号相近而放行。

UU 为闭源程序。本项目不承诺游戏加速，不自动修改 LAN 或原厂 Java 权限规则，不替用户重启光猫。进程退出及网络规则清理由闭源程序行为影响，不能保证所有故障自动恢复。

## 构建与测试

在仓库根目录使用 Windows PowerShell 5.1：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-Routing.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-Gui.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-InstallState.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-FrameworkRepair.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-ConfigCleanup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-Skd847n.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tools/build_gui.ps1
```

构建产物为 `unified/ZteOntUuWol.exe`，运行 `--self-test` 检查内嵌脚本，`--check` 检查界面初始化。这些测试不代替实机重启与远程开机验收。

统一版维护入口在 `unified/`。根目录旧 F7615 脚本与测试仍为兼容实现，不能据其旧版本号判断统一工具版本。原厂导出文件、绑定身份和私有备份不应进入源码或发行包。

[使用说明](../INSTALL.txt) · [验证记录](../unified/VALIDATION.txt) · [常见问题](TROUBLESHOOTING.md)
