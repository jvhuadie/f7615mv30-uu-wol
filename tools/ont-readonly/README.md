# 中兴光猫只读检测工具 v0.6.1

[下载单文件 EXE](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/probe-v0.6.1/ZTE-ONT-readonly-v0.6.1.exe) · [工具包 ZIP](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/probe-v0.6.1/ZTE-ONT-readonly-v0.6.1.zip) · [使用说明](INSTALL.txt) · [提交适配资料](https://share.fnnas.net/s/a6cea4a86c714bdf87)

独立 Windows 单文件 EXE，用于收集中兴光猫不同型号、固件的适配资料。需要已有 Telnet 权限；不负责解锁或开启 Telnet。Windows 需 PowerShell 5.1 / .NET Framework，无需 Python、SDK 或管理员运行。

## 使用与反馈

1. 电脑接入光猫局域网，运行 EXE，填写实际地址、端口、用户名和密码。默认值不是所有设备的通用密码。
2. 可选填写机身标签型号、硬件版本，点击「开始只读检测」。
3. 完成后检查同名 TXT 顶部摘要、采集覆盖、提示与内容。
4. 点击「提交适配资料」。**网页「请输入您的名字」填写机身标签设备型号，如 F7005MV3、G7615V2；不要填写姓名，不确定时填写「型号未知」。**
5. 上传生成的普通检测 ZIP 原文件。报告不会自动上传，发送前仍应检查脱敏结果。

不要公开原始报告、设备配置、绑定或密钥，也不要把它们附在公开 Issue。

## 采集范围与边界

共 49 个固定只读分组，覆盖身份/发行版本、CPU/内存、运行库与加载器、固定程序 ELF 头、工具/BusyBox applet、分区挂载、常见 init、Java/OSGi、CU/UPT、SAF 位置、应用目录、用户态进程权限与命名空间、容器启动文件元数据、LXC 属性白名单、网络接口/策略默认路由及 DNS 配置存在性。

不安装 UU、不上传脚本、不写光猫文件、不改自启、不停止服务或重启。不进入容器或执行 saf console，不尝试控制台密码，不发起外网测试。自定义 rc.local/run.sh 仅看元数据，不读取内容；不读取账号数据库、UU 绑定文件、进程命令行或环境变量，不导出完整程序、文件系统或固件原始内容。

型号线索保留来源，用户填写信息独立保存；来源不一致时显示冲突。`ZTE 133` 作为板级描述显示，构建时间与软件版本分开，不能直接当作产品型号或固件版本。

JSON schemaVersion 为 3，逐组记录返回码、耗时、提示、截断与范围，并列出未完成/中断分组。COMPLETE 仅表示所有分组返回，不表示每个子命令成功或设备已兼容。输出有候选项、行数和字符边界，未命中不能证明不存在，未知固件仍可能需要补证。

报告隐藏当前输入密码和常见地址、敏感字段及 URL 凭据；明确版本字段保留点分版本号。自动脱敏不能替代发送前检查。

## 构建与测试

仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/ont-readonly/tools/build.ps1
python tools/ont-readonly/tests/test_collect.py
$env:PROBE_BUSYBOX = 'C:\path\to\busybox.exe'
python tools/ont-readonly/tests/test_boot_hints.py
python tools/ont-readonly/tests/test_single_exe.py --exe tools/ont-readonly/dist/ZTE-ONT-readonly-v0.6.1.exe
```

Python 与 BusyBox 仅供开发测试；EXE 内嵌运行资源并逐项核对 SHA-256，正常退出清理本实例临时目录。普通采集共 21 项离线/模拟测试及窗口核对；49 项扩展采集尚未完成实机验收。
