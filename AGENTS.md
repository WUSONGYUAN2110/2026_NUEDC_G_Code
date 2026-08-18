# AX7020 Vivado/Vitis 2022.2 Development Guide / 开发入口

This repository targets the AX7020 board, device `xc7z020clg400-2`, and Vivado/Vitis 2022.2. Use `doc/AX7020开发板 IO引脚分配总表.md` as the only source for board-level I/O assignments.

本仓库固定使用 AX7020、器件 `xc7z020clg400-2` 和 Vivado/Vitis 2022.2。板级 IO 只参考 `doc/AX7020开发板 IO引脚分配总表.md`。

## English quick reference

- Treat `config.tcl` as the single configuration entry point. The default flow is pure PL; use the scripted Vivado/Vitis flow for PS+PL designs.
- Keep persistent RTL, constraints, simulation sources, and software in `rtl/`, `sim/`, and `vitis/src/`. Do not hand-edit generated projects, caches, logs, or published artifacts.
- Use the smallest command that matches the change: `sync` for source-list changes, `sim` for simulation, `synth` or `build` for RTL work, and `all` only for project structure, BD, IP, or PS changes.
- A successful run must report `SUCCESS:` and `RESULT: status=PASS`; simulation must also report `TEST_PASS`. Builds must be fully routed, pass DRC, and have non-negative setup/hold timing when timed paths exist.
- Confirm board power, connections, and target files before JTAG, serial, ILA, or QSPI operations. Run QSPI preflight first, preview cleanup before deleting generated files, and enable ILA only when explicitly needed.

## 1. Fixed boundaries / 固定边界

- `config.tcl` 是项目、顶层、TB、纯 PL/PS+PL、并行数、启动模式和 Vitis 名称的唯一配置入口。
- 默认纯 PL：`use_bd=0`、PS 外设关闭、`boot_mode=none`、ILA 关闭，只发布 bit。
- PS+PL 由 Vivado 发布 bit/XSA，再由 Vitis 构建软件和启动镜像。
- DDR/MIO 由 `prj/bd.tcl` 管理；DDR 参数已经过验证，不需要修改。

| 路径 | 用途 |
| --- | --- |
| `rtl/` | 持久 RTL、XDC、头文件和初始化数据 |
| `sim/` | 持久 testbench、模型和仿真数据 |
| `vitis/src/` | 持久软件源码 |
| `config.tcl` | 唯一项目配置 |
| `prj/*.tcl`、`vitis/run.tcl`、`scripts/` | 自动化脚本；只有配置无法表达需求时才修改 |
| XPR、runs/cache/gen/srcs、Vitis workspace、日志、captures | 可再生，不手改 |
| bit/XSA/LTX、ELF/BIN、manifests | 脚本发布，不手改 |

## 2. Entry points and daily workflow / 入口和日常流程

```text
.\scripts\invoke-xilinx.cmd Vivado <step> [参数]
.\scripts\invoke-xilinx.cmd Vitis <step> [参数]
```

旧的 `-Tool ... -Step ...` 写法仍兼容。仿真使用 `-TbTop`、`-SimTime`，Vitis 需要指定硬件时使用 `-Xsa`。

`Vivado check` 不是每次开发的必经步骤；它用于首次工程、结构/配置变化、故障定位和发布前，检查配置、fileset、工程结构及发布物。日常开发直接按变更类型选择最小命令：

| 变更或目标 | 最小命令 |
| --- | --- |
| 首次工程、修改器件/顶层/`use_bd`/BD/IP/PS 外设 | `Vivado all` |
| 增删或移动 `rtl/`、`sim/` 文件 | `Vivado sync`，再按需 `sim/synth/build` |
| 修改已入工程 RTL/XDC/初始化数据 | `Vivado synth`；需要 bit 时 `Vivado build` |
| 只修改仿真 | `Vivado sim -TbTop <TB> -SimTime <TIME>` |
| 修改已有软件源码 | `Vitis build` |
| 新增软件源 | `Vitis sync` → `Vitis build` |
| PS+PL 硬件改变 | `Vivado all` → `Vitis update` → `Vitis build` |
| 完整 PS+PL 发布 | `Vitis all` |

`synth/build/sim` 会在昂贵步骤前检查工程结构和 fileset 是否同步。`sync` 不处理 BD/IP；结构或 PS/IP 变化必须使用 `all`。`all` 会重建工程和缓存，不用于普通 RTL 迭代。

## 3. Success criteria / 成功标准

- 必须同时看到 `SUCCESS:`、`RESULT: status=PASS` 和预期产物；仿真还必须有独立的 `TEST_PASS`。
- build 必须无 ERROR/FATAL/Critical Warning，设计完全布线，DRC 无 Error，已有时序路径 Setup/Hold 非负。
- 失败先看启动器摘要，再在对应 `logs/` 中定位第一个真实错误；不要用更重流程掩盖问题。
- 不手动编辑生成工程、bit/XSA/ELF/BIN/manifest；除非用户要求，不清理生成物。

## 4. Programming, boot, and cleanup / 下载、启动和清理

- 纯 PL 只下载 manifest 绑定的 bit；PS+PL 按 bit → FSBL → ELF 进行 JTAG 下载。
- JTAG、串口、ILA、QSPI 写入前必须确认供电、连接和目标文件；下载不等于板级功能验收。
- QSPI 先执行 `.\vitis\program-qspi.ps1 -PreflightOnly`，确认后才执行带 `-YesIHaveConfirmedBoardReady` 的写入命令。
- 清理先预览：`.\scripts\clean-generated.cmd -DryRun`。只有用户明确要求时才使用 `-IncludePublished`。
- ILA 默认关闭；只有用户明确要求或仿真无法复现硬件问题时才启用。
