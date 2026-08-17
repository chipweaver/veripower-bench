---
Status: approved
---

# CoralNPU 标量+浮点子系统规格（CoreMiniAxi）

定义本子系统必须实现的架构、行为与接口;在标量整数核基础上增加**单精度浮点(F)与 BF16(Zfbfmin)**。

**标注**
- **[A]** = 遵循下方"引用标准"中的外部公开标准。
- **[B]** = 本设计特定要求,以本文为准。
- 本文未约束者由 RTL 自行决定(见 §8)。

**引用标准（原文落盘于 `handoff/refs/`）**
- **[RV-U]** RISC-V Unprivileged ISA:RV32I、M、Zicsr、Zifencei。原文 `riscv-spec.html`。
- **[RV-B]** RISC-V Bit-Manipulation,Zbb。原文 `riscv-spec.html`。
- **[RV-F]** 单精度浮点 F(FLEN=32);数值语义(含 IEEE 754 基础运算/舍入/NaN 装箱/异常标志)以手册 F 章为准。原文 `riscv-spec.html`。
- **[RV-BF16]** Zfbfmin(标量 BF16↔FP32 转换)。原文 `riscv-spec.html`。
- **[RV-OPC]** 逐位指令编码(opcode/funct)。原文 `riscv-opcodes/extensions/*`。
- **[RV-P]** RISC-V Privileged Architecture:Machine 模式 CSR、异常/中断/trap、`mstatus.FS`。原文 `riscv-spec.html`。
- **[AXI]** ARM AMBA AXI Protocol Specification(IHI 0022 Issue L)。原文 `IHI0022L_amba_axi_protocol_spec.txt`。各可变轴取值见 §6.2.1。

---

## 1. 指令集 [A]

`rv32imf_zicsr_zifencei_zbb_zfbfmin`,仅 **Machine 模式**。语义与编码遵循 [RV-U]/[RV-B]/[RV-F]/[RV-BF16]。

- **RV32I**:基础整数,含 `FENCE`、`ECALL`、`EBREAK`、`MRET`。
- **M**:`MUL MULH MULHSU MULHU DIV DIVU REM REMU`。
- **Zicsr**:`CSRRW CSRRS CSRRC CSRRWI CSRRSI CSRRCI`。
- **Zifencei**:`FENCE.I`。
- **Zbb**:`ANDN ORN XNOR CLZ CTZ CPOP MAX MAXU MIN MINU SEXT.B SEXT.H ZEXT.H ROL ROR RORI ORC.B REV8`。
- **F**(单精度,FLEN=32):加载/存储 `FLW FSW`;算术 `FADD.S FSUB.S FMUL.S FDIV.S FSQRT.S FMADD.S FMSUB.S FNMADD.S FNMSUB.S`;比较/符号/最值 `FMIN.S FMAX.S FEQ.S FLT.S FLE.S FSGNJ.S FSGNJN.S FSGNJX.S`;分类 `FCLASS.S`;转换 `FCVT.W.S FCVT.WU.S FCVT.S.W FCVT.S.WU`;搬移 `FMV.X.W FMV.W.X`。
- **Zfbfmin**:BF16↔FP32 标量转换 `FCVT.BF16.S FCVT.S.BF16`(BF16 以 FP32 NaN-box 形式存于浮点寄存器)。

不支持 C(压缩)、D(双精度)、Zfh(半精度)、V(向量)扩展及用户/监督模式。

---

## 2. 控制状态寄存器（CSR）

### 2.1 标准 Machine 模式 CSR [A]
地址与位域遵循 [RV-P]:

`mstatus 0x300` · `misa 0x301` · `mie 0x304` · `mtvec 0x305` · `mstatush 0x310` · `mscratch 0x340` · `mepc 0x341` · `mcause 0x342` · `mtval 0x343` · `mip 0x344`。

计数器:`mcycle 0xB00` · `minstret 0xB02` · `mcycleh 0xB80` · `minstreth 0xB82`。
对 `minstret` 或 `minstreth` **任一**半字的 CSR 写,均抑制该指令自身的 `minstret` 自增。

`mstatus.FS`(浮点状态,位[14:13])须实现:F 指令写浮点寄存器/fflags 时置 Dirty;复位为 Off/Initial。`misa` 须反映 `I M F` 及 Zbb 相应位。

### 2.2 浮点 CSR [A]
| 地址 | 名称 | 说明 |
|---|---|---|
| 0x001 | fflags | 累积异常标志 `NV DZ OF UF NX`(位[4:0]),浮点运算按 [RV-F] 累积 |
| 0x002 | frm | 舍入模式(位[2:0]):RNE/RTZ/RDN/RUP/RMM;非法值(5–7)在浮点运算动态取用时按非法处理 |
| 0x003 | fcsr | `{frm[7:5], fflags[4:0]}` 的合并视图 |

### 2.3 机器识别 CSR [B]（只读常量）
| 地址 | 名称 | 值 |
|---|---|---|
| 0xF11 | mvendorid | `0x00000426` |
| 0xF12 | marchid | `0x00000000` |
| 0xF13 | mimpid | `0x00000000` |
| 0xF14 | mhartid | `0x00000000` |

### 2.4 自定义 CSR [B]（读写,复位值 0）
| 地址 | 名称 |
|---|---|
| 0x7C0 – 0x7C7 | mcontext0 – mcontext7 |
| 0x7E0 | mpc |
| 0x7E1 | msp |
| 0xFCC / 0xFD0 / 0xFD4 | kscm2 / kscm3 / kscm4 |

写只读 CSR、或访问未实现的 CSR 地址,按非法指令处理(见 §3.1)。

---

## 3. 异常 / 中断 / 停机

### 3.1 同步异常 → 可恢复 trap 到 mtvec [A]（遵循 [RV-P]）
同步异常按 [RV-P] Machine 模式 trap 语义,**可恢复(非终止)**:锁存 `mepc`(出错指令 PC)、`mcause`、`mtval`;`mstatus.MPIE ← MIE`、`MIE ← 0`;跳 `mtvec`(direct base);`MRET` 恢复 `MIE ← MPIE` 返回 `mepc` 续跑。

| 异常 | mcause | mtval |
|---|---|---|
| 非法指令 / 非法·未实现 CSR 访问 | 2 | 出错指令编码 |
| 取指地址不对齐(跳转/分支目标) | 0 | 目标地址 |
| 取指访问错误 | 1 | 取指地址 |
| Load 访问错误 | 5 | 访问地址 |
| Store 访问错误 | 7 | 访问地址 |
| 环境调用 ECALL(M 模式) | 11 | 0 |

> 遵循 [RV-P] trap 章节。同步异常须能 trap+handler+`MRET` 续跑,非终止。
> 浮点运算异常(溢出/无效操作等)**不产生 trap**,仅按 [RV-F] 累积到 `fflags`。
> 非自然对齐的 load/store 由硬件透明支持,不产生同步异常;故本表无 mcause 4/6。

### 3.2 中断 → trap 到 mtvec [A]（遵循 [RV-P]，可恢复）
外部/定时器/软件中断,经 `mstatus.MIE` 与 `mie` 对应位使能后,trap 到 `mtvec`:置 `mepc`、`mcause`(最高位=1)、`mstatus.MPIE ← MIE`、`MIE ← 0`。`MRET` 恢复。可恢复,不终止。

### 3.3 停机与致命错误 [B]
- `EBREAK` → 拉高 `io_halted`,干净停机。
- `mpause`(编码 `0x08000073`)→ 拉高 `io_halted`,停机。
- `io_fault`:不可恢复致命错误指示(与 `io_halted` 同拉);正常运行不产生(同步异常按 §3.1 可恢复 trap)。

---

## 4. 内存映射 [B]

| 区域 | 地址范围 | 大小 | 属性 |
|---|---|---|---|
| ITCM | 0x00000000 – 0x00001FFF | 8 KB | 可执行可读;复位后取指起点 0x0 |
| DTCM | 0x00010000 – 0x00017FFF | 32 KB | 读写 |
| 控制寄存器接口 | 0x00030000 – 0x00031FFF | 8 KB 窗 | 经从口访问(非 RISC-V CSR 空间);完整 map 见 §4.1 |
| EXTMEM | 0x20000000 | 4 MB | 读写(经主口) |
| DDR | 0x80000000 | 2 GB | 读写(经主口) |

ITCM/DTCM 为单周期访问的紧耦合存储;EXTMEM/DDR 经 AXI 主口访问。

### 4.1 控制寄存器窗 map [B]
控制窗(0x00030000 起)经从口读写;地址 → 行为(窗内无效地址读回 SLVERR):

| 偏移(自 0x30000) | 读 | 写 | 说明 |
|---|---|---|---|
| `+0x000` | OKAY,回显 | OKAY | 复位控制 |
| `+0x004` | OKAY,回显 | OKAY | 起始 PC |
| `+0x008` | OKAY,状态值 ∈ {0,1,3} | OKAY(不改为任意) | 复位/运行状态 |
| `+0x00C … +0x0FC` | **SLVERR** | OKAY | 无效 |
| `+0x100 … +0x11C`(8 字) | OKAY | — | 8 个可读 CSR 回读字(内容实现可观测,不校验值) |
| 其余窗内(保留窗 `+0x800 … +0x817` 除外) | **SLVERR** | — | 无效地址读回 SLVERR |

---

## 5. 浮点单元 [A]

- **浮点寄存器**:`f0`–`f31`,每个 FLEN=32 位;与整数寄存器独立。
- **语义**:所有 F 与 Zfbfmin 指令的数值结果、NaN 传播、非规格化、舍入(取自 `frm`,或指令静态舍入域)与异常标志累积均遵循 [RV-F]/[RV-BF16] 与 IEEE 754-2008。
- **BF16**:以 FP32 NaN-box 形式存于浮点寄存器;仅 Zfbfmin 的转换指令,不含 BF16 算术。
- **数据通路实现自由 [C]**:浮点运算单元的微架构(流水级数、延迟、是否复用外部 FPU IP)不受约束,只要外部可见行为符合上述 [A] 语义。

---

## 6. 顶层接口 [B]

顶层模块名须为 **`CoreMiniAxi`**。**浮点为内部实现,不新增任何顶层端口**;端口与 §6.1/§6.2 同标量核。

### 6.1 时钟 / 复位 / 边带
| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `io_aclk` | in | 1 | 时钟 |
| `io_aresetn` | in | 1 | 异步复位,低有效 |
| `io_boot_addr` | in | 32 | 复位启动向量输入:复位释放时的取指起始 PC 初值(功能运行时实际起始 PC 由 §7 控制寄存器 `0x00030004` 覆盖)|
| `io_halted` | out | 1 | 停机指示 |
| `io_fault` | out | 1 | 不可恢复致命错误指示(见 §3.3);正常运行不产生(同步异常按 §3.1 可恢复 trap)|
| `io_wfi` | out | 1 | WFI 状态:执行 `WFI` 进入等待时拉高,被使能的中断唤醒后拉低 |
| `io_irq` | in | 1 | 外部中断(高有效)|
| `io_timer_irq` | in | 1 | 定时器中断 |
| `io_software_irq` | in | 1 | 软件中断 |
| `io_te` | in | 1 | 测试使能,功能运行置 0 |
| `io_dm_req_valid` | in | 1 | 调试模块(DM)请求有效——见下注 |
| `io_dm_rsp_ready` | in | 1 | 调试模块(DM)响应就绪——见下注 |

> **DM 范围注**:`io_dm_req_valid`/`io_dm_rsp_ready` 作为**被忽略的输入端口**声明即可(等效常接空闲,不影响正常执行)。完整 DM 通道其余信号与任何调试/追踪观测端口不属本层范围。

### 6.2 AXI 接口（协议遵循 [AXI]；命名与位宽为 [B]）
两个 AXI 接口,`addr=32 位, data=128 位, id=6 位`:
- **`io_axi_slave_*`**:从接口。外部 host 经此载入 ITCM/DTCM 与访问控制寄存器。
- **`io_axi_master_*`**:主接口。本子系统经此访问 EXTMEM/DDR。

信号按下列通道结构展平命名——`io_axi_{slave|master}_<通道>_<握手/字段>`:

| 通道 | 握手 | 字段 |
|---|---|---|
| `write_addr` | `_valid` `_ready` | `_bits_addr[32] _bits_prot[3] _bits_id[6] _bits_len[8] _bits_size[3] _bits_burst[2] _bits_lock[1] _bits_cache[4] _bits_qos[4]` |
| `write_data` | `_valid` `_ready` | `_bits_data[128] _bits_last _bits_strb[16]` |
| `write_resp` | `_valid` `_ready` | `_bits_id[6] _bits_resp[2]` |
| `read_addr` | `_valid` `_ready` | 同 `write_addr` 字段 |
| `read_data` | `_valid` `_ready` | `_bits_data[128] _bits_id[6] _bits_resp[2] _bits_last` |

示例:`io_axi_master_write_addr_valid`、`io_axi_slave_read_data_bits_data`。

#### 6.2.1 AXI 参数与行为约定 [A]

各可变轴取值如下(语义以 [AXI] 对应条款为准,原文见 `handoff/refs/`):

| 可变轴 | 本项目取值 | [AXI] 条款 |
|---|---|---|
| 协议版本 | ARM IHI 0022 Issue L(见 `sources.lock`) | 全文 |
| 通道 | 全五通道 AW/W/B/AR/R(读写皆有) | §A1 通道结构 |
| 位宽 | addr=32, data=128, id=6, 无 user | 信号表(§6.2 [B]) |
| 突发类型 | 主口只发 **INCR**;**从口须正确处理 INCR / FIXED / WRAP 三种**(外部 host 可发任意突发类型与任意 `AxLEN`,含 FIXED/WRAP 超 16 拍;从口不得因长度回 SLVERR 或丢数据) | §A3 Burst |
| 传输 size | 主口 ∈ {1,2,4} 字节/拍;从口按 128 位全宽拍处理 | §A3 |
| **事务标识(id)回显** | **必须逐事务回显:`BID`=对应 `AWID`、`RID`=对应 `ARID`**(哪怕单未决也须回对) | §A5 Transaction identifiers |
| 未决/交织 | 从口**至少支持 host 侧流水/交织事务**并逐事务保存回显 id;可单未决(backpressure)但 id 不得串味 | §A5, §A6 Ordering |
| 握手 | 遵循 VALID/READY 依赖(不得等对方先动)、无组合环 | §A3.2 依赖关系 |
| 响应码 | OKAY(正常) / SLVERR(越界或错误);不产生 DECERR | §A4 响应信令 |
| 独占访问(lock) | **不支持**:主口 `lock=0`;从口忽略 `lock`,独占请求按普通处理并回 OKAY | §A7 Atomic accesses |
| cache/prot/qos/region | 主口 `prot=2`、`cache=0`、`qos=0`、`id=0`;从口不据其改变行为 | §A4 |
| 低功耗接口 | 不实现 | §A14(不适用) |

> 从口的 WRAP 在起始地址所属的**单个全宽拍(16 字节)**内回卷,回卷边界不随 `AxLEN` 变化(窄于 [AXI] §A3.4.1 的 `Size × Length`,本设计如此约定);起始地址可不对齐。

---

## 7. 复位与启动 [B]

`io_aresetn` 低有效;复位释放后需等待一个时钟周期。外部 host 经从接口引导:
1. 将程序镜像写入 ITCM(起点 0x00000000)。
2. 将起始 PC 写入控制寄存器 `0x00030004`(覆盖 `io_boot_addr` 提供的复位向量初值)。
3. 向控制寄存器 `0x00030000` 先写 1(放行),再写 0(解复位)。
4. 处理器从该起始 PC 执行,直至停机(run-to-completion,无操作系统、无重入)。

**性能**:任一 ITCM 驻留、不含外部访存的测试程序,自核释放至 `io_halted` 拉高须在 **1000 个 `io_aclk` 周期**内完成。

**重入**:核停机(`io_halted` 拉高)后,host 可再经从口**改写或读取** ITCM/DTCM 并重复第 2-3 步重新释放,无需 `io_aresetn` 复位;重新释放后核**必须**读到 host 最新写入的数据。

---

## 8. 实现自由（非规范；界定未被约束的范围）

以下由 RTL 自行决定:流水线结构与级数、取指与分支预测策略、指令派发宽度、冒险/前递/调度、**指令退休顺序**、乘除与浮点运算的实现方式与延迟周期、浮点单元是否复用外部 FPU IP、TCM 与任何缓存的组织方式、AXI 事务的时序与交织(在符合 [AXI] 前提下)。
