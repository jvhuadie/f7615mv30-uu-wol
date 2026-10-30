# 光猫 · UU 远程开机助手

一个 Windows 单文件工具，自动识别已验证固件的 **中兴 F7615MV30 / F7005MV3 / G7615V2、创维 SK-D847N**，完成 UU 远程开机服务的安装、状态检查、启停、自启与卸载恢复。

**当前正式版：v1.2.0（2026-10-31）**。新增创维 SK-D847N：参考设备的安装、云连接、启停、绑定恢复和重启自启已实测通过，用户已确认远程开机成功。已有正常安装无需重装，更换电脑端 EXE 不会自动修改光猫。

[下载管理工具 EXE](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/v1.2.0/zte-ont-uu-wol-v1.2.0.exe) · [安装包 ZIP](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/v1.2.0/zte-ont-uu-wol-v1.2.0.zip) · [Release](https://github.com/jvhuadie/zte-ont-uu-wol/releases/tag/v1.2.0) · [安装说明](INSTALL.txt) · [验证记录](unified/VALIDATION.txt)

> **F7615MV30 安装后必须手动重启光猫**，待网络恢复后确认服务、App 在线和远程开机。已观察到首次运行可能停止，重启后恢复，原因尚未定位。工具不会自动重启光猫。

## 支持范围

以下为已匹配指纹的参考固件结果，更新至 2026-10-31，不代表同型号的全部运营商版本或其他固件。

| 型号 | 启动方式 | 已完成验证 | 适用边界 |
|---|---|---|---|
| F7615MV30 | Wi-Fi 配置回调，光猫端 v0.3 | 重启自启、远程开机、日志轮转；本轮全新安装与重启后云连接 | 安装后需手动重启；本轮重装后未重新确认移动数据唤醒 |
| F7005MV3 | 原厂 OSGi 插件 | 安装、重启、远程开机、卸载恢复；原始 Andlink 健康跳过 | 原始故障版本自动修复全流程仍待另一台实机验证 |
| G7615V2 | CU/procd 框架 | 用户确认本轮测试及重启成功（2026-10-30） | [限定指纹和说明](docs/G7615V2.md) |
| 创维 SK-D847N | 原厂 OSGi 插件，受限辅助程序 | 安装、启停、云 TCP、保留绑定及完整卸载恢复、重启自启；用户确认远程开机 | [限定指纹和权限说明](docs/SK-D847N.md)；测试手机网络条件未单独记录 |
| 其他型号 / 未知固件 | 暂不放行安装 | 先使用只读采集器提交资料 | 型号相近或检测完成不等于已适配 |

四型号均未完成长期稳定性及多设备、多固件覆盖验证。Windows 工具与光猫端服务版本分别维护，版本号不同属正常情况。

每次操作先核对型号、aarch64 架构与固件摘要。F7005 与创维还核对各自启动环境；未知或交叉固件会停止，不会改用另一型号的流程。

## 快速使用

1. 电脑连接目标光猫局域网，运行 EXE；需已有 root Telnet 权限，工具不提供解锁。
2. 填写实际地址、用户名、密码，点击 **检查状态**。默认 `192.168.1.1:23`、`root`、`Zte521`。**创维本次参考设备密码为 `Pon521`，请手动填写**；密码以自己的设备为准，不自动尝试其他密码。
3. 首次使用点击 **安装 / 升级**，自动选用对应方案。已正常运行的设备无需重装；已有安装或操作中断时先检查状态。
4. F7615 安装后手动重启；所有新安装均应验证重启自启、UU App 在线和实际远程开机。创维原厂框架启动较慢，本次在开机约 268 秒时观察到服务恢复，不能作为固定耗时保证。
5. 全新安装在 UU App 中绑定并配置目标电脑；电脑接电、接有线网，开启主板与网卡 WOL，再使用手机移动数据测试唤醒。

Windows 需 PowerShell 5.1 / .NET Framework，无需 Python、SDK 或 Windows 管理员权限。Telnet 不加密，请在可信局域网使用。

## 服务管理与恢复

| 操作 | F7615MV30 / G7615V2 | F7005MV3 | 创维 SK-D847N |
|---|---|---|---|
| 服务启停与自启 | 分别控制 | 联动 | 联动 |
| 保留绑定卸载 | 安装与绑定留在光猫，可恢复 | 绑定备份到电脑后清理安装 | 停用自有插件并撤销辅助程序权限，安装与绑定留在光猫 |
| 恢复服务 | 恢复保留安装 | 选择绑定 TGZ 后恢复安装 | 恢复保留安装并启动 |
| 完全卸载 | 按各自流程清理 | 解除保护、撤销授权并清理自有安装 | 先备份绑定 JSON，再撤销权限并清理自有插件与目录 |

F7005 备份在电脑“文档/F7005MV3-UU-WOL”，创维绑定 JSON 在“文档/SK-D847N-UU-WOL”。创维完整卸载后重新安装，可先在 **型号选项** 选择绑定 JSON。电脑已有备份和 UU App 设备记录不会被删除。

**F7005 必须通过本工具卸载**，直接从原厂插件页面删除可能遗留受保护文件。其 Andlink 自动修复只针对已验证且明确异常的版本；原始版本健康则跳过，未知版本停止，修复有备份和超时回退。详见[使用说明](INSTALL.txt)。

## 新型号只读采集与反馈

**采集器 v0.7.2** 独立发布，用于中兴、创维等光猫的适配资料收集，需要已有 Telnet 权限。

[下载采集器 EXE](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/probe-v0.7.2/ZTE-ONT-readonly-v0.7.2.exe) · [ZIP 与 Release](https://github.com/jvhuadie/zte-ont-uu-wol/releases/tag/probe-v0.7.2) · [采集说明](tools/ont-readonly/README.md) · [提交资料](https://share.fnnas.net/s/a6cea4a86c714bdf87)

- 63 组固定只读采集：型号来源、架构、版本、固件摘要、工具与运行库、存储挂载、启动框架、Java/OSGi、CU/UPT、目录权限和进程能力等。
- 新增创维 OSGi 缓存、插件登记、权限白名单及厂商管理程序静态线索；修复终端长命令截断。SK-D847N 已实机完成 **63/63** 组，27 项自动测试通过。
- 不安装 UU、不执行插件管理、不改配置或重启，不导出完整文件系统、固件、程序、账号数据库或 UU 绑定。报告在电脑保存，由用户检查后上传。

填写机身标签型号及硬件版本，检测后先检查 TXT 顶部摘要和提示，再上传生成的 ZIP 原文件。**收集网页“请输入您的名字”请填写设备型号，如 SK-D847N、G7615V2；不要填姓名，不明时填“型号未知”。** 不要把报告发布到公开 Issue。

`ZTE 133` 是板级描述，不能直接当作商品型号；报告分别保留系统来源和用户填写信息。COMPLETE 仅表示分组全部返回，不代表每条命令成功或已完成安装适配。脱敏结果仍需人工检查。

## 文件、权限与源码

- 管理工具使用 `v*` 标签，采集器使用 `probe-v*` 标签；各自 ZIP 为可运行安装包，GitHub 自动生成的 Source code 为源码。
- Release 提供 EXE、ZIP、使用说明、验证记录及 SHA-256 清单。EXE 内嵌白名单资源，释放后逐项校验摘要，正常退出清理自己的临时目录。
- 统一工具代码位于 [`unified/`](unified/)，采集器位于 [`tools/ont-readonly/`](tools/ont-readonly/)；根目录旧 F7615 入口保留供兼容和历史查阅。
- F7005 的 UU 以普通用户及 `CAP_NET_RAW` 运行；固定 PID 辅助程序权限与文件保护另有限定。创维使用固定用途 setuid 辅助程序，在校验后降为 UID 107，仅保留 `CAP_NET_RAW`，不把 UU 作为 root 运行。详细边界见各型号文档。
- 发行包不含设备绑定、原始固件导出或个人配置。不要公开 `.sn`、`.uuplugin_uuid`、`uu.conf`、绑定 JSON/TGZ 或框架备份。手动输入密码仅在内存中使用；预填默认密码是公开内嵌配置。

构建与回归测试（Windows PowerShell 5.1）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-Routing.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-Gui.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tests/Test-Skd847n.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File unified/tools/build_gui.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/ont-readonly/tools/build.ps1
```

自产 Java 与原生辅助程序源码在各型号 `src/` 目录；构建封装不会重新编译闭源 UU 程序，厂商编译依赖不公开分发。完整测试入口与限制见[实现与维护](docs/RESEARCH.md)。

[安装说明](INSTALL.txt) · [验证记录](unified/VALIDATION.txt) · [更新日志](CHANGELOG.md) · [常见问题](docs/TROUBLESHOOTING.md) · [创维说明](docs/SK-D847N.md) · [G7615V2 说明](docs/G7615V2.md)

## 关于与协作署名

维护者：[jvhuadie](https://github.com/jvhuadie)。项目由维护者主导并提供设备和使用验证，**OpenAI Codex** 协助代码实现、型号适配分析、排查、测试和文档整理；感谢提供设备资料与实测反馈的用户。

本项目是社区远程开机辅助工具，非网易、中兴或创维官方产品，不承诺游戏加速适配。UU 闭源程序和厂商组件的权利归各自权利人所有。
