# 2026 年全国大学生电子设计竞赛 G 题代码工程

[English](README.md) | 中文

## 周期信号测量分析装置

基于**黑金 AX7020 / Zynq-7020**的周期信号测量分析装置工程，面向 2026 年全国大学生电子设计竞赛 G 题的学习、仿真和二次开发。

工程包含完整的 FPGA + ARM 处理链路：

```text
LTC2208 ADC 采集
    ↓
PL 侧数据接收与预处理
    ↓
FIR 抽取滤波 → Blackman-Harris 窗 → FFT 频谱分析
    ↓
Zynq PS 侧测量算法
    ↓
串口屏显示测量结果
```

主要测量内容包括周期信号的频率、峰峰值、有效值、频谱和谐波相关信息。

## 1. 硬件组成

- 黑金 AX7020 开发板；
- LTC2208 高速 ADC 模块；
- 淘晶驰TJC8048X570_011C串口屏；
- 信号源、连接线和供电设备。

### 整体连接图

![AX7020、LTC2208 与串口屏整体连接图](doc/hardware/overall_setup.jpg)

### 硬件连接说明

- **AX7020 与淘晶驰串口屏**：串口屏连接 PS UART1，工程默认使用 `MIO8` / `MIO9`，其中 `MIO8` 为发送端 `TX`，`MIO9` 为接收端 `RX`。接线时使用交叉连接：AX7020 `TX` 接串口屏 `RX`，AX7020 `RX` 接串口屏 `TX`，并连接 `GND`。
- **AX7020 与 LTC2208**：当前工程使用 LTC2208 的 **B 通道**，模块连接 AX7020 的 IO1（J10）接口。B 通道数据对应 `adc_b_data[15:0]`，采样驱动时钟对应 `adc_b_clk`；A 通道在当前设计中未启用。具体管脚分配见 [`rtl/ltc2208_ax7020_io1.xdc`](rtl/ltc2208_ax7020_io1.xdc)。
- **被测信号输入**：将信号源接入 LTC2208 模块的 B 通道输入，并确保 AX7020、LTC2208 和串口屏之间按硬件接口要求供电、共地。

### 硬件参考

#### 黑金 AX7020 / Zynq-7020 开发板

![黑金 AX7020 开发板](doc/hardware/ax7020_product.png)

[淘宝商品链接](https://c.tb.cn/h.87HmlmyfVovgydo?tk=yaU0TYGoELO)

#### LTC2208 高速 ADC 模块

![LTC2208 高速 ADC 模块](doc/hardware/ltc2208_product.png)

[淘宝商品链接](https://c.tb.cn/h.87HnJrG5rrqyx6M?tk=sqKfTYGpP6z)

#### 淘晶驰TJC8048X570_011C串口屏

![淘晶驰串口屏](doc/hardware/serial_screen_product.png)

[淘宝商品链接](https://c.tb.cn/h.8jgpUamCFA43wRa?tk=TJnbTYGqnWH)

板级管脚分配见 [`doc/AX7020开发板 IO引脚分配总表.md`](doc/AX7020开发板%20IO引脚分配总表.md)。

## 2. 开发环境

| 项目 | 配置 |
| --- | --- |
| 开发板 | 黑金 AX7020 |
| FPGA | `xc7z020clg400-2` |
| ADC | LTC2208 |
| 串口屏 | 淘晶驰 TJC8048X570_011C |
| ZYNQ7020开发工具 | Vivado 2022.2、Vitis 2022.2 |
| 串口屏上位机 | USART HMI（淘晶驰上位机/IDE） |
| 操作系统 | Windows + PowerShell |

工程配置统一由 [`config.tcl`](config.tcl) 管理，具体目录边界和开发规则见 [`AGENTS.md`](AGENTS.md)。

## 3. 目录结构

```text
rtl/                   FPGA RTL、XDC 和 DSP 初始化数据
vitis/src/             Zynq PS 端 C 语言源码
sim/                   Testbench、C 自检入口和 Python 黄金模型
sim/host_include/      主机侧替代 Xilinx 头文件
scripts/               构建、下载、清理和调试脚本
prj/                   Vivado Tcl 工程脚本和 Block Design 配置
vitis/                 Vitis Tcl、启动配置和 QSPI 脚本
doc/                   G 题 PDF、AX7020 IO 说明和硬件图片
config.tcl             工程统一配置入口
AGENTS.md              工程开发说明
2026_diansai.HMI       串口屏工程文件
```

仓库保留源码、脚本、配置和学习资料，不包含 Vivado/Vitis 工作区及编译产物。

## 4. 快速开始

1. 安装 Vivado/Vitis 2022.2；
2. 准备 AX7020、LTC2208 和淘晶驰 TJC8048X570_011C 串口屏；
3. 下载并安装 [淘晶驰上位机/IDE](http://wiki.tjc1688.com/start/download_ide.html)，用于打开并下载 `2026_diansai.HMI` 串口屏工程；
4. 阅读 [`doc/G题_周期信号测量分析装置.pdf`](doc/G题_周期信号测量分析装置.pdf)，了解题目要求；
5. 检查 [`config.tcl`](config.tcl) 中的工程配置；
6. 根据需要执行以下命令。

### Vivado

```powershell
.\scripts\invoke-xilinx.cmd Vivado check
.\scripts\invoke-xilinx.cmd Vivado sim -TbTop tb_measurement_pl -SimTime 5ms
.\scripts\invoke-xilinx.cmd Vivado synth
.\scripts\invoke-xilinx.cmd Vivado build
.\scripts\invoke-xilinx.cmd Vivado all
```

### Vitis

```powershell
.\scripts\invoke-xilinx.cmd Vitis build
.\scripts\invoke-xilinx.cmd Vitis all
```

常用选择：

- 只修改 RTL：执行 `Vivado synth`，需要位流时执行 `Vivado build`；
- 只修改仿真：执行 `Vivado sim`；
- 修改 Block Design、IP 或 PS 配置：执行 `Vivado all`；
- 修改 Vitis 软件源码：执行 `Vitis build`；
- PS+PL 硬件更新后：先执行 `Vivado all`，再执行 `Vitis update` 和 `Vitis build`。

## 5. 仿真与算法学习

`sim/` 中包含以下内容：

- `tb_measurement_pl.sv`：测量处理链路 Testbench；
- 其他 Testbench：用于验证 ADC 接口、滤波和数据饱和处理；
- `golden_model_test.py`：Python 参考模型，用于对比滤波、窗函数、FFT 和测量算法；
- `measurement_c_selftest_runner.c`：主机侧 C 语言自检入口。

仿真流程应输出 `TEST_PASS`。建议先从 Testbench 和 Python 黄金模型入手，再阅读 RTL 和 Vitis 算法代码。

## 6. 下载与调试

```powershell
.\scripts\download-jtag.cmd
.\vitis\program-qspi.ps1 -PreflightOnly
.\scripts\capture-ila.cmd
.\scripts\clean-generated.cmd -DryRun
```

下载、QSPI 和 ILA 使用方法见 [`AGENTS.md`](AGENTS.md) 及对应脚本。

## 7. 推荐阅读顺序

1. 阅读 G 题 PDF，明确输入信号、测量内容和任务要求；
2. 阅读 `config.tcl` 和 `AGENTS.md`，了解工程入口；
3. 运行 `sim/` 中的 Testbench 和 `golden_model_test.py`；
4. 阅读 `rtl/`，理解采集、滤波、窗函数、FFT 和 AXI-Stream 数据通路；
5. 阅读 `vitis/src/measurement_algorithm.c`，理解 PS 侧测量算法；
6. 阅读 `vitis/src/hmi_protocol.c`，了解串口屏通信；
7. 连接 AX7020 和外围硬件进行板级调试。

## 8. 相关资料

- [`AGENTS.md`](AGENTS.md)：工程规则、构建命令和清理说明；
- [`config.tcl`](config.tcl)：工程配置入口；
- [`doc/G题_周期信号测量分析装置.pdf`](doc/G题_周期信号测量分析装置.pdf)：竞赛题目资料；
- [`doc/AX7020开发板 IO引脚分配总表.md`](doc/AX7020开发板%20IO引脚分配总表.md)：AX7020 管脚说明。
