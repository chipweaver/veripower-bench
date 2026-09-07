---
Status: approved
---

# usbdev — 硬件化设计请求

## 0. 背景与目标

`usbdev` 是一个 USB 2.0 全速（12 Mbps）**设备端**控制器，挂在片上总线上。它在
D+/D− 线上实现完整的 USB 设备侧协议：位填充、CRC5/CRC16、PID 译码、SETUP/IN/OUT
事务、数据翻转位、STALL/NAK 应答、以及链路层的复位 / 挂起 / 恢复 / 唤醒。软件通过
TL-UL 总线读写 44 个寄存器来配置端点、投递与取回数据包，并通过 18 条中断线获知事件。

数据包缓冲区是一块片上 RAM，软件与硬件通过三个缓冲区 FIFO（AV OUT / AV SETUP / RX）
交接缓冲区编号，而不是搬运数据。

交付物：可综合的 `usbdev` RTL，满足 §3 接口、§4 约束、§6 PPA 目标，并通过 §7 验收。

## 1. 交付给你的输入（权威）

- `refs/opentitan-usbdev/` —— **功能、寄存器、接口的唯一权威**：
  - `README.md` —— 特性清单与总体描述
  - `theory_of_operation.md` —— 工作原理：端点模型、缓冲区交接、事务流程、
    链路状态机、时钟恢复与频率校准、AON 唤醒
  - `registers.md` —— **完整寄存器映射**：44 个寄存器的偏移、字段、位宽、读写属性、
    复位值，以及数据包缓冲区的内存窗口。这是寄存器行为的逐位真源
  - `interfaces.md` —— 时钟、总线接口、外设引脚、中断清单
  - `programmers_guide.md` —— 软件使用序列
- `refs/opentitan-comportability/comportability.md` —— comportable IP 规范：
  寄存器、中断、alert、总线接入的约定
- `refs/opentitan-tlul/` —— TL-UL 总线协议（含 SECDED integrity）的操作性真源。
  `TlulProtocolChecker.md` 列出逐信号的协议属性；评测会把这套检查器以
  `EndpointType("Device")` bind 到你的顶层。注意该文档自己说明的区别：Device
  模式下**请求通道（Channel A）的属性是 assume**，约束的是测试平台怎么发请求，
  不检查你；真正断言在你身上的是 9 条——响应通道 5 条（`respOpcode_A`
  `legalDParam_A` `respSzEqReqSz_A` `respMustHaveReq_A` `dDataKnown_A`），
  外加 4 条**错误应答义务**：非法 opcode、size 与 mask 不符、size/mask 越界、
  地址与 size 不对齐，这四种请求你都必须最终以 `d_error` 应答
  （`legalAOpcodeErr_A` `sizeGTEMaskErr_A` `sizeMatchesMaskErr_A`
  `addrSizeAlignedErr_A`）。这四条是别处没写的设计要求

**不在交付范围内**：上游的 `hw/ip/usbdev/data/usbdev.hjson`。它经 `regtool` 可直接
生成 `usbdev_reg_pkg` + `usbdev_reg_top`（约占整个模块三分之二的代码量）。
`registers.md` 是同一真值的人类可读形式；寄存器文件由你自己按它实现。

同样不提供：任何 USB 的 RTL 实现、测试平台或参考模型。

USB 2.0 协议本身以 USB-IF《Universal Serial Bus Specification Revision 2.0》为准；
该文档 USB-IF 版权、不可再分发，需自备。`theory_of_operation.md` 已覆盖本模块实现
的全部条款，可独立据其实现。

## 2. 功能范围

**端点**：`NEndpoints = 12`，IN 与 OUT 各 12 个，逐端点可使能、可设 STALL、
可设为同步（isochronous）、可设为控制端点。

**事务**：SETUP / OUT / IN；DATA0/DATA1 翻转位维护与软件可写覆盖；
ACK / NAK / STALL / 无应答的选择规则按 `theory_of_operation.md`
（含 STALL 相对 NAK 与 SETUP 的优先级）。

**物理层**：NRZI 编解码、位填充与去填充、SYNC 检测、EOP 生成与检测、
CRC5（令牌）与 CRC16（数据）、差分与单端两种接收路径、引脚翻转（pinflip）、
`tx_use_d_se0` 两种发送编码。错误须分别上报：CRC 错、PID 错、位填充错、
链路 IN/OUT 错。

**缓冲区管理**：一块片上数据包 RAM，通过 AV OUT FIFO、AV SETUP FIFO（软件交给硬件
的空缓冲区）与 RX FIFO（硬件交回软件的已填缓冲区）三个队列交接编号。
空 / 溢出 / 满 的条件与中断按规格。

**链路层**：上电、断开、复位、挂起、恢复、host lost 的状态机；帧号（frame）计数；
SOF 参考脉冲输出用于外部振荡器校准（`usb_ref_val_o` / `usb_ref_pulse_o`）。

**AON 唤醒接口**：挂起时把总线监视移交给一个独立的常开模块（不在本设计范围内），
通过 `usb_aon_*` 一组信号握手；该组信号跨到 `clk_aon_i` 域。

**计数器**：OUT / IN / NODATA-IN / 错误四组事件计数器，逐端点可屏蔽、可复位。

**不做**：USB 主机侧、高速（480 Mbps）、USB 3.x、片外 PHY 的模拟部分。

## 3. 接口与集成契约

这一节是**硬约束**：顶层模块名、端口名、端口类型、以及你必须提供的 package 符号，
必须逐字符与下表一致——评测把你的 RTL 直接替换进一个不属于你的验证环境。

**顶层模块名须为 `usbdev`。端口表（50 个），类型逐字符如下——
总线与 alert 用 OpenTitan 的 packed struct，编译器保证字段位置，你不需要算任何位偏移：**

| 端口 | 方向 | 类型 |
|---|---|---|
| `clk_i` | in | `logic` |
| `rst_ni` | in | `logic` |
| `clk_aon_i` | in | `logic` |
| `rst_aon_ni` | in | `logic` |
| `tl_i` | in | `tlul_pkg::tl_h2d_t` |
| `tl_o` | out | `tlul_pkg::tl_d2h_t` |
| `alert_rx_i` | in | `prim_alert_pkg::alert_rx_t [NumAlerts-1:0]` |
| `alert_tx_o` | out | `prim_alert_pkg::alert_tx_t [NumAlerts-1:0]` |
| `cio_usb_dp_i` | in | `logic` |
| `cio_usb_dn_i` | in | `logic` |
| `usb_rx_d_i` | in | `logic` |
| `cio_usb_dp_o` | out | `logic` |
| `cio_usb_dp_en_o` | out | `logic` |
| `cio_usb_dn_o` | out | `logic` |
| `cio_usb_dn_en_o` | out | `logic` |
| `usb_tx_se0_o` | out | `logic` |
| `usb_tx_d_o` | out | `logic` |
| `cio_sense_i` | in | `logic` |
| `usb_dp_pullup_o` | out | `logic` |
| `usb_dn_pullup_o` | out | `logic` |
| `usb_rx_enable_o` | out | `logic` |
| `usb_tx_use_d_se0_o` | out | `logic` |
| `usb_aon_suspend_req_o` | out | `logic` |
| `usb_aon_wake_ack_o` | out | `logic` |
| `usb_aon_bus_reset_i` | in | `logic` |
| `usb_aon_sense_lost_i` | in | `logic` |
| `usb_aon_bus_not_idle_i` | in | `logic` |
| `usb_aon_wake_detect_active_i` | in | `logic` |
| `usb_ref_val_o` | out | `logic` |
| `usb_ref_pulse_o` | out | `logic` |
| `ram_cfg_i` | in | `prim_ram_1p_pkg::ram_1p_cfg_req_t` |
| `ram_cfg_o` | out | `prim_ram_1p_pkg::ram_1p_cfg_rsp_t` |
| `intr_pkt_received_o` | out | `logic` |
| `intr_pkt_sent_o` | out | `logic` |
| `intr_powered_o` | out | `logic` |
| `intr_disconnected_o` | out | `logic` |
| `intr_host_lost_o` | out | `logic` |
| `intr_link_reset_o` | out | `logic` |
| `intr_link_suspend_o` | out | `logic` |
| `intr_link_resume_o` | out | `logic` |
| `intr_av_out_empty_o` | out | `logic` |
| `intr_rx_full_o` | out | `logic` |
| `intr_av_overflow_o` | out | `logic` |
| `intr_link_in_err_o` | out | `logic` |
| `intr_link_out_err_o` | out | `logic` |
| `intr_rx_crc_err_o` | out | `logic` |
| `intr_rx_pid_err_o` | out | `logic` |
| `intr_rx_bitstuff_err_o` | out | `logic` |
| `intr_frame_o` | out | `logic` |
| `intr_av_setup_empty_o` | out | `logic` |

TL-UL 的字段语义与协议见 `refs/opentitan-tlul/README.md`；comportable IP 的
寄存器/中断/alert/总线约定见 `refs/opentitan-comportability/comportability.md`。

### 寄存器文件：你的交付物是描述，不是那几千行 RTL

真实的 comportable 流程里，寄存器文件不是手写的。comportability 规范原文：
*"Each peripheral must define its collection of registers in the specified
register format. The registers are automatically generated in the form of
hardware, software, and documentation collateral."* 参考实现里
`usbdev_reg_top` 是生成物，文件头写着 auto-generated。

所以本任务要求同样的分界：

1. 照 `refs/opentitan-usbdev/registers.md` **写一份机读的寄存器描述**（偏移、字段、
   位宽、读写属性、复位值）。这是设计判断所在，也是要评审的东西。
2. **由它生成**寄存器文件 RTL（`usbdev_reg_top` 一类）。用什么生成由你决定——
   自己写脚本、用现成工具、或其它办法都可以，本文不规定。
3. 同时交付 `usbdev_reg_pkg`：至少包含验证环境读取的参数（见下）。

评测侧的寄存器模型是从**规格那一侧**独立生成的，所以你的映射与规格是否逐位一致
会被直接比对——偏移错、属性选错、复位值填错都会挂在 CSR 类测试上。

**评测环境提供、你可以直接用的**：

- OpenTitan 的 `prim` / `prim_generic` / `tlul` 三个模块库：`prim_subreg`
  （寄存器字段）、`prim_intr_hw`（中断）、`prim_fifo_sync`、`prim_flop_2sync`
  （跨时钟域同步）、`prim_secded_*`（SECDED 编解码）、`tlul_adapter_reg`
  （总线到寄存器的适配）等。这与真实签核要求一致——`usbdev` 的签核清单里
  `PRE_VERIFIED_SUB_MODULES_V2` 一项写的就是 "Only prim and tlul sub-modules used"。
- 这些库需要的全部类型 package，以及 `usbdev_pkg`（手写的设计/验证共用类型），
  你不需要写它们。

**不提供**：本 IP 自己 `rtl/` 目录下的任何设计模块（例化 `usbdev_core` 之类的名字
会报模块找不到），以及 `usbdev_reg_pkg` 和寄存器文件——那是你按上面第 1–3 条交付的。

**寄存器地址映射、字段语义与数据包缓冲区的内存窗口**以 `registers.md` 为准，逐位一致。

## 4. 约束

- **两个时钟域**：`clk_i`（USB，48 MHz 名义）与 `clk_aon_i`（常开，低频）。
  `usb_aon_*` 一组信号跨这两个域，必须按 CDC 规范同步。CDC 检查会看这里。
- **异步输入**：`cio_usb_dp_i` / `cio_usb_dn_i` / `usb_rx_d_i` / `cio_sense_i`
  来自片外，与任何时钟无关系，必须同步。
- **存储**：目标工艺只有标准单元库（无 memory 宏）。数据包缓冲区 RAM 与全部 FIFO
  均以标准单元实现。
- **语言**：SystemVerilog。本 IP 是 comportable 外设，接口本身就建立在
  `tlul_pkg` 的 packed struct 上，寄存器文件也由描述生成——这是它的真实流程。
- 整体可综合；空 stub、blackbox、`initial` 加载的存储数组视为未实现。

## 5. 微架构：你的职责

协议引擎的状态机划分、缓冲区 RAM 的端口与仲裁、CRC 与位填充电路结构、
时钟恢复方式、寄存器文件的内部组织、模块层次与文件划分，全部由你设计。
本文不提供、也不约束——约束只来自 §3 接口、§4 环境与 §6 PPA。

## 6. PPA 目标

**时序**：SDC 时钟周期 10 ns（100 MHz，`clk_i`）；`clk_aon_i` 与 `clk_i` 声明为
异步时钟组。综合与 STA 后 setup / hold 均无违例。

**面积**：≤ 200,000 NAND2 等效门（含数据包缓冲区）。
NAND2 等效门 = Total cell area ÷ 库 NAND2X1 面积。

**功耗**：无目标（功能设计）。

## 7. 验收与签核

**功能（唯一功能判据）**：一组held-out的 UVM 测试全部 PASS。它们来自上游 OpenTitan
为本 IP 写的验证环境，**对你不可见**，只通过 §3 的端口与寄存器映射观察你的设计——
把你的 RTL 直接替换进去运行。所以 §3 的接口契约逐字符成立是功能验收的前提：
端口或 package 符号不合，测试连编译都到不了。

**其他验收门**：

- **结构覆盖率**：行 / 条件 / 状态机 / 翻转均 > 90%，作用域限定在你的 RTL
  （不含验证环境）。
- **功能覆盖率 > 90%**：你要写 covergroup，覆盖点从你自己的测试点清单来。
  结构覆盖率单独达标是不够的——只加激励不加检查就能把它刷上去。这与真实签核
  一致：本 IP 的签核清单把 `SIM_CODE_COVERAGE_V2` 与 `SIM_FUNCTIONAL_COVERAGE_V2`
  并列为两道独立的门，另有 `FUNCTIONAL_COVERAGE_IMPLEMENTED`（covergroup 已实现）
  和 `TESTPLAN_REVIEWED`（测试点清单已评审）。
- lint / CDC / **RDC** clean（0 Error、0 Warning）。RDC 是复位域交叉，真实签核里
  与 CDC 分列两道门（本 IP 清单的 `RDC_COMPLETE` / `RDC_SETUP`）；本设计有
  `rst_ni` 与 `rst_aon_ni` 两个独立复位域，所以这道门在这里是实的——参考实现
  实测为 0 条跨越。SpyGlass goal：`rdc/rdc_verify_struct`
  （方法学 `GuideWare/2016.06/block/rtl_handoff`）。
- §6 的时序与面积目标。
