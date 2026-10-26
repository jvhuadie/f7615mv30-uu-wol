# 中兴光猫只读检测与完整备份工具 v0.6

[下载单文件 EXE](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/probe-v0.6.0/ZTE-ONT-readonly-v0.6.exe) · [工具包 ZIP](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/probe-v0.6.0/ZTE-ONT-readonly-v0.6.zip) · [详细说明](INSTALL.txt) · [提交脱敏适配报告](https://share.fnnas.net/s/a6cea4a86c714bdf87)

需要已有 Telnet 登录权限；Windows PowerShell 5.1 / .NET Framework，无需另装 Python 或以 Windows 管理员运行。默认连接值不是所有型号的通用密码。

## 两种用途

| 功能 | 内容与保存方式 | 适用用途 |
|---|---|---|
| 开始只读检测 | 49 个固定采集分组；脱敏 TXT/JSON 打包为 ZIP | 新型号适配资料反馈 |
| 完整备份导出 | 文件系统 tar、MTD/eMMC 原始数据或两者；保存在电脑 PRIVATE-full-backup-* 目录 | 仅供本人保管和私下离线研究，包含未脱敏账号、密钥或绑定资料 |

两者均不在光猫上生成临时包、不安装 UU、不修改自启、不停服务、不重启。完整备份只读源数据，使用电脑磁盘流式接收，不冻结文件系统，也不提供恢复或刷写功能。

## 普通检测与反馈

1. 电脑接入光猫局域网，运行 EXE，填写实际地址、端口与登录信息。
2. 可选填写机身标签型号与硬件版本，点击「开始只读检测」。
3. 检查 TXT 顶部摘要、采集覆盖、提示及原文。型号线索不等于已确认型号或已适配。
4. 点击「提交适配资料」。**网页「请输入您的名字」填写机身标签设备型号，如 F7005MV3、G7615V2；不要填姓名。不确定时填「型号未知」。**
5. 上传普通检测生成的 ZIP 原文件。报告不会自动上传；请先检查脱敏结果。

普通报告不读取账号数据库、绑定文件、进程参数或环境变量，不导出程序/固件原始内容。不要把原始备份、配置、报告提交到公开 Issue。完整备份完成后窗口会禁用资料提交按钮，重新完成普通检测后才恢复。

## 49 个分组的覆盖

- 身份与版本：主机名、板级描述、设备树兼容信息、发行版本、构建时间、CPU、内存与关键组件指纹。`ZTE 133` 单独作为板级描述，不当作产品型号。
- 运行环境：库与加载器元数据、固定程序 ELF 头、工具/BusyBox applet、内核能力线索、块设备和可写分区。
- 启动与框架：传统 init、常见服务目录、Wi-Fi 回调引用、Java/OSGi、CU/UPT 框架、SAF 位置及固定原厂启动脚本。
- 容器与应用：用户态进程权限、根目录和命名空间、不同命名空间的启动文件元数据及根挂载、LXC 明确属性白名单、常见应用/持久化目录。
- 网络：接口、桥、策略规则、各表默认路由、DNS 文件存在性和 nameserver 数量；不发起外网测试请求。

只定位 saf，不执行 saf console、不尝试 upt 或其他控制台密码、不进入容器。自定义 rc.local、run.sh 仅看存在性、行数、大小与指纹，不读取内容。程序中的路径字符串仅是线索，不证明入口会执行。

报告逐组记录耗时、返回码、提示、输出截断和采集范围，另列出未完成/中断分组。COMPLETE 仅表示所有分组返回，不表示每个子命令成功；输出有行数、候选项和字符数边界，未命中不能证明不存在。仍可能有未知固件的特殊入口需要后续补证。

## 完整备份的范围与限制

完整备份要求光猫端 root、BusyBox hexdump；文件系统模式还要求 tar 支持 -C 与 --exclude。可选「文件系统 + 固件」「仅文件系统归档」「仅固件原始映像」。不支持的工具或设备会明确失败，不降级伪装成完整导出。

- 文件系统：生成 filesystem.tar，归档当前可见的持久化文件，保留账号/密钥/绑定等原始内容。按实际挂载排除虚拟文件系统、运行时目录及外接介质，排除项写入 filesystem-excludes.json；不跟随符号链接。/var 若是持久化目录则归档，若是 tmpfs 则排除。默认上限 8 GiB，可通过 Backup.ps1 的 MaxArchiveMiB 参数调整（128–65536 MiB）。
- 固件：优先读取 /proc/mtd 对应的 /dev/mtdblockN。存在名称明确且覆盖全部大小的 whole/full flash 分区时导出它，避免再导出重叠分区；否则逐个分区导出。无 MTD 时读取 mmcblkN 主设备及可见 boot0/boot1；不扫描或导出 USB/SD 的 sdX 设备。计划和大小写入 flash-layout.json，设备总量超过 64 GiB 或电脑空间不足时停止。
- 校验：块设备读取大小必须符合声明，接收时计算本地 SHA-256，完成后再次读取设备指纹比较。变化、传输/读取异常及校验失败保留 .partial，清单明确标记不完整。文件系统 tar 记录来源/编码管道状态与本地 SHA-256；它没有静态源文件的远端整体指纹。
- 取消与保存：可点击「取消备份」，关闭会话并保留电脑已收到的数据与清单。Telnet 十六进制传输较慢，不支持断点续传；请检查 backup-manifest.json，不要只凭文件存在判断成功。

运行中读取不能保证所有文件/分区来自同一时刻；再次哈希一致也不等于具备可恢复的一致性快照。原始映像不包含 NAND OOB/ECC 或 eMMC RPMB，不是厂商升级包，不能直接视为可刷回固件。完整备份包含未脱敏敏感信息，**不要上传到适配资料收集页或公开仓库**。

## 构建与测试

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/ont-readonly/tools/build.ps1
python tools/ont-readonly/tests/test_collect.py
$env:PROBE_BUSYBOX = 'C:\path\to\busybox.exe'
python tools/ont-readonly/tests/test_boot_hints.py
python tools/ont-readonly/tests/test_backup.py
python tools/ont-readonly/tests/test_single_exe.py --exe tools/ont-readonly/dist/ZTE-ONT-readonly-v0.6.exe
```

默认构建到 tools/ont-readonly/dist，资源内嵌并逐项核对 SHA-256。Python 与 BusyBox 仅供开发测试，不是 Windows EXE 的外部依赖。原始报告、设备文件和备份不会随源码或 Release 分发。

本版本仅完成离线/模拟测试和窗口检查；新增分组、备份及不同固件的实际表现仍需逐台验证。
