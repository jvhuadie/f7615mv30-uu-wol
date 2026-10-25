# 中兴光猫只读检测工具 v0.5

用于收集不同型号、固件的适配资料，需要已有 Telnet 登录权限。在 Windows 上独立运行，不需要安装 UU、Python 或管理员权限。

[下载 EXE](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/probe-v0.5.0/ZTE-ONT-readonly-v0.5.exe) · [下载工具包](https://github.com/jvhuadie/zte-ont-uu-wol/releases/download/probe-v0.5.0/ZTE-ONT-readonly-v0.5.zip) · [使用说明](INSTALL.txt) · [提交适配资料](https://share.fnnas.net/s/a6cea4a86c714bdf87)

## 运行与反馈

1. 将电脑接入光猫局域网，运行 EXE，填写实际 Telnet 连接信息。默认值不是所有设备的通用密码。
2. 可选填写机身标签型号、硬件版本，然后点击「开始只读检测」。
3. 完成后打开结果目录，检查 TXT 顶部的身份摘要与报告内容。
4. 点击「提交适配资料」或打开上方收集链接。**网页「请输入您的名字」请填写设备型号，例如 F7005MV3、G7615V2，不要填写姓名；不确定时填写「型号未知」。**
5. 上传生成的 ZIP 原文件，内含 report.txt、report.json。部分采集结果同样可以反馈。工具不会自动上传。

不要把报告、设备绑定文件或配置备份提交到公开 Issue。需要公开讨论时，只填写产品型号、固件版本、采集状态及不含个人信息的问题描述；原始报告通过收集链接提交。

## 识别与采集范围

报告顶部、JSON identity 字段和文件名包含型号线索与架构，并保留来源、软件版本和 /bin/cspd 完整 SHA-256。主机名只能提供待核实线索；用户填写信息独立保存，来源不一致会标记冲突。

`/proc/device-tree/model` 中的 `ZTE 133` 属于板级描述，不能单凭它判断商品型号。请结合机身标签、管理页面与固件指纹确认。

共 27 个固定只读采集分组，覆盖系统、CPU/内存、运行库、分区、网络、启动入口、插件机制与现有 UU 元数据。不上传脚本、不安装组件、不修改自启、不停止服务、不重启。报告保存在电脑上。不会读取完整进程命令行、账号配置、固件镜像或 UU 绑定文件。

报告隐藏当前输入密码及常见地址、敏感字段；明确版本字段中的点分版本号保留。发送前仍需自行检查内容。识别出型号不表示已经支持安装 UU。

## 构建与验证

Windows PowerShell 5.1 / .NET Framework：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/ont-readonly/tools/build.ps1
```

默认生成 `tools/ont-readonly/dist/ZTE-ONT-readonly-v0.5.exe`。源码、测试与构建脚本公开；构建产物通过 Release 分发。EXE 内嵌资源经 SHA-256 校验，正常退出清理本实例临时目录。

开发测试另需 Python 3；shell 测试需指定本机 BusyBox 路径：

```powershell
python tools/ont-readonly/tests/test_collect.py
$env:PROBE_BUSYBOX = 'C:\path\to\busybox.exe'
python tools/ont-readonly/tests/test_boot_hints.py
python tools/ont-readonly/tests/test_single_exe.py --exe tools/ont-readonly/dist/ZTE-ONT-readonly-v0.5.exe
```

v0.5 已通过 9 项模拟采集/身份识别测试、3 项 shell 测试与 5 项单文件测试，并检查窗口布局。新版本尚未重新实机采集；此前在 F7615MV30 的早期采集验证不能替代其他设备或固件的验收。
