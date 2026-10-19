# eadk-rk-flash

EADK 瑞芯微（Rockchip）Windows 烧录组件：**EADK RK Flash**。

对外（经 Gateway）：`http://127.0.0.1:18081/rk-flash/`  
本机直连：`http://127.0.0.1:18172/rk-flash/`

组件 id / tool：`rk-flash`（禁止泛名 `flash`，以便后续其它平台烧录组件并存）。

## 能力

- 整包 `update.img`、单分区镜像烧写（基于官方 `upgrade_tool`）
- Agent 接口：`/rk-flash/help`、`/rk-flash/api/help`
- 本机路径 / HTTP 上传 / 网络镜像 URL（须为具体文件）
- 多板 `LocationID`（`select`）；单板可不指定

## 目录

```text
eadk/                 EADK 启动器与 HTTP 服务
scripts/              CLI 烧写脚本（flash.ps1）
tools/upgrade_tool/   官方 Windows CLI
skills/rk-flash/      Agent Skill
rk_flash_config.json.example
说明书.md             CLI 说明书
```

## 构建与组装

```bat
eadk\build.bat
```

产物：`output\eadk-rk-flash.exe`。由 EADK Manager 的 `assemble_kit.bat` 拷入 `components\rk-flash\`。

## Agent

见 [skills/rk-flash/SKILL.md](skills/rk-flash/SKILL.md)。

CLI 细节见 [说明书.md](说明书.md)。
