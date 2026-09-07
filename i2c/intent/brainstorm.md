---
Status: approved
---

# i2c — 硬件化设计请求

## 0. 背景与目标

`i2c` 是挂在片上总线上的 I²C 外设：既能做总线控制器（Controller，向若干目标发起
传输），也能做总线目标（Target，响应外部控制器）。软件通过 TL-UL 总线读写它的寄存器
组来配置时序、投递命令、收发数据，并通过 16 条中断线获知事件。

交付物：可综合的 `i2c` RTL，满足 §3 接口、§4 约束、§6 PPA 目标，并通过 §7 验收。

## 1. 交付给你的输入（权威）

- `refs/opentitan-i2c/` —— **功能、寄存器、接口的唯一权威**：
  - `README.md` —— 特性清单与总体描述
  - `theory_of_operation.md` —— 工作原理：时序参数、FIFO 语义、拉伸、仲裁、超时
  - `registers.md` —— **完整寄存器映射**：32 个寄存器的偏移、字段、位宽、读写属性、
    复位值。这是寄存器行为的逐位真源
  - `interfaces.md` —— 时钟、总线接口、外设引脚、中断清单
  - `programmers_guide.md` —— 软件使用序列（初始化、发起传输、处理中断）
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

**不在交付范围内**：上游的 `hw/ip/i2c/data/i2c.hjson`。它经 `regtool` 可直接生成
`i2c_reg_pkg` + `i2c_reg_top`（约占整个模块一半的代码量）。`registers.md` 是同一真值
的人类可读形式；寄存器文件由你自己按它实现。

同样不提供：任何 I²C 的 RTL 实现、测试平台或参考模型。

I²C 协议本身以 NXP UM10204 (rev. 6) 为准；该文档 NXP 版权、不可再分发，需自备。
`theory_of_operation.md` 已覆盖本模块实现的全部条款，可独立据其实现。

## 2. 功能范围

**双模式**：Controller 与 Target，运行时由寄存器选择，可同时使能。

**速率**：Standard-mode (100 kbaud)、Fast-mode (400 kbaud)、Fast-mode Plus (1 Mbaud)。
时序由寄存器以核心时钟周期数给出（THIGH/TLOW/T_R/T_F/THD_STA/TSU_STA/…），不是硬编码。

**Controller 必备**：START / STOP / RESTART 条件、7 位目标地址、ACK/NACK、
时钟拉伸（作为控制器时容忍目标拉伸）、多控制器时钟同步与总线仲裁、总线空闲检测、
NACK / SCL 干扰 / SDA 干扰 / SDA 不稳定 / 超时 / 传输完成的中断。

**Target 必备**：地址匹配（含掩码与广播）、自动时钟拉伸、可编程自动 ACK、
读传输时 TX FIFO 空 / 读结束时 TX FIFO 非空 / TX 溢出 / ACQ FIFO 满 /
控制器 ACK 后发 STOP / 控制器中途停发 SCL 的中断。

**四个字节格式化队列**：Controller 的 FMT（发送：地址或写数据）与 RX（接收读数据）；
Target 的 TX（发送读数据）与 ACQ（接收写数据及控制信息）。每队列有可编程水位中断、
可被软件复位、满/溢出行为按 `theory_of_operation.md`。

**Override 模式**：软件直接驱动并观察 SCL / SDA（调试用）。

**不做**：10 位地址、SMBus 专有层、DMA。

## 3. 接口与集成契约

这一节是**硬约束**：顶层模块名、端口名、端口类型、以及你必须提供的 package 符号，
必须逐字符与下表一致——评测把你的 RTL 直接替换进一个不属于你的验证环境。

**顶层模块名须为 `i2c`。端口表（32 个），类型逐字符如下——
总线与 alert 用 OpenTitan 的 packed struct，编译器保证字段位置，你不需要算任何位偏移：**

| 端口 | 方向 | 类型 |
|---|---|---|
| `clk_i` | in | `logic` |
| `rst_ni` | in | `logic` |
| `ram_cfg_i` | in | `prim_ram_1p_pkg::ram_1p_cfg_req_t` |
| `ram_cfg_o` | out | `prim_ram_1p_pkg::ram_1p_cfg_rsp_t` |
| `tl_i` | in | `tlul_pkg::tl_h2d_t` |
| `tl_o` | out | `tlul_pkg::tl_d2h_t` |
| `alert_rx_i` | in | `prim_alert_pkg::alert_rx_t [NumAlerts-1:0]` |
| `alert_tx_o` | out | `prim_alert_pkg::alert_tx_t [NumAlerts-1:0]` |
| `racl_policies_i` | in | `top_racl_pkg::racl_policy_vec_t` |
| `racl_error_o` | out | `top_racl_pkg::racl_error_log_t` |
| `cio_scl_i` | in | `logic` |
| `cio_scl_o` | out | `logic` |
| `cio_scl_en_o` | out | `logic` |
| `cio_sda_i` | in | `logic` |
| `cio_sda_o` | out | `logic` |
| `cio_sda_en_o` | out | `logic` |
| `lsio_trigger_o` | out | `logic` |
| `intr_fmt_threshold_o` | out | `logic` |
| `intr_rx_threshold_o` | out | `logic` |
| `intr_acq_threshold_o` | out | `logic` |
| `intr_rx_overflow_o` | out | `logic` |
| `intr_controller_halt_o` | out | `logic` |
| `intr_scl_interference_o` | out | `logic` |
| `intr_sda_interference_o` | out | `logic` |
| `intr_stretch_timeout_o` | out | `logic` |
| `intr_sda_unstable_o` | out | `logic` |
| `intr_cmd_complete_o` | out | `logic` |
| `intr_tx_stretch_o` | out | `logic` |
| `intr_tx_threshold_o` | out | `logic` |
| `intr_acq_stretch_o` | out | `logic` |
| `intr_unexp_stop_o` | out | `logic` |
| `intr_host_timeout_o` | out | `logic` |

TL-UL 的字段语义与协议见 `refs/opentitan-tlul/README.md`；comportable IP 的
寄存器/中断/alert/总线约定见 `refs/opentitan-comportability/comportability.md`。

### 寄存器文件：你的交付物是描述，不是那几千行 RTL

真实的 comportable 流程里，寄存器文件不是手写的。comportability 规范原文：
*"Each peripheral must define its collection of registers in the specified
register format. The registers are automatically generated in the form of
hardware, software, and documentation collateral."* 参考实现里
`i2c_reg_top` 是生成物，文件头写着 auto-generated。

所以本任务要求同样的分界：

1. 照 `refs/opentitan-i2c/registers.md` **写一份机读的寄存器描述**（偏移、字段、
   位宽、读写属性、复位值）。这是设计判断所在，也是要评审的东西。
2. **由它生成**寄存器文件 RTL（`i2c_reg_top` 一类）。用什么生成由你决定——
   自己写脚本、用现成工具、或其它办法都可以，本文不规定。
3. 同时交付 `i2c_reg_pkg`：至少包含验证环境读取的参数（见下）。

评测侧的寄存器模型是从**规格那一侧**独立生成的，所以你的映射与规格是否逐位一致
会被直接比对——偏移错、属性选错、复位值填错都会挂在 CSR 类测试上。

**评测环境提供、你可以直接用的**：

- OpenTitan 的 `prim` / `prim_generic` / `tlul` 三个模块库：`prim_subreg`
  （寄存器字段）、`prim_intr_hw`（中断）、`prim_fifo_sync`、`prim_flop_2sync`
  （跨时钟域同步）、`prim_secded_*`（SECDED 编解码）、`tlul_adapter_reg`
  （总线到寄存器的适配）等。这与真实签核要求一致——`i2c` 的签核清单里
  `PRE_VERIFIED_SUB_MODULES_V2` 一项写的就是 "Only prim and tlul sub-modules used"。
- 这些库需要的全部类型 package，以及 `i2c_pkg`（手写的设计/验证共用类型），
  你不需要写它们。

**不提供**：本 IP 自己 `rtl/` 目录下的任何设计模块（例化 `i2c_core` 之类的名字
会报模块找不到），以及 `i2c_reg_pkg` 和寄存器文件——那是你按上面第 1–3 条交付的。

**寄存器地址映射与字段语义**以 `registers.md` 为准，逐位一致。

## 4. 约束

- **时钟与复位**：单一时钟域 `clk_i`；`rst_ni` 同步、低有效。
- **异步输入**：`cio_scl_i` / `cio_sda_i` 来自片外，与 `clk_i` 无关系，必须同步并
  按 `theory_of_operation.md` 的去毛刺要求处理。CDC 检查会看这里。
- **存储**：目标工艺只有标准单元库（无 memory 宏）。FIFO 以标准单元实现。
- **语言**：SystemVerilog。本 IP 是 comportable 外设，接口本身就建立在
  `tlul_pkg` 的 packed struct 上，寄存器文件也由描述生成——这是它的真实流程。
- 整体可综合；空 stub、blackbox、`initial` 加载的存储数组视为未实现。

## 5. 微架构：你的职责

状态机划分、FIFO 实现、时序计数器结构、寄存器文件的内部组织、模块层次与文件划分，
全部由你设计。本文不提供、也不约束——约束只来自 §3 接口、§4 环境与 §6 PPA。

## 6. PPA 目标

**时序**：SDC 时钟周期 12.5 ns（80 MHz）；综合与 STA 后 setup / hold 均无违例。

**面积**：≤ 90,000 NAND2 等效门。NAND2 等效门 = Total cell area ÷ 库 NAND2X1 面积。

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
- lint / CDC clean（0 Error、0 Warning）。本设计单一复位域，RDC（复位域交叉）
  不适用。
- §6 的时序与面积目标。
