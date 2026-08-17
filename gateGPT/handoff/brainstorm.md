---
Status: approved
---

# microgpt_core — 硬件化设计请求

## 0. 背景与目标

microgpt_core 是一个字符级名字生成器（NamesGPT）的推理核：一个单层字符级
transformer。算法团队已交付位精确的定点参考实现；
本任务是把该算法硬件化为可综合 RTL（microgpt_core），嵌入现有 host 系统，按增量
解码逐 token 生成名字。

交付物：可综合的 microgpt_core RTL，满足 §3 接口、§4 约束、§6 PPA 目标，并通过 §7
验收。

## 1. 交付给你的输入（权威）

- `reference/fixedpoint.py` + `reference/model.py` —— **位精确参考算法**，是所有数值
  行为的唯一权威。RTL 必须在 Q5.11 定点下与之逐比特一致。
- `reference/weights.npz` —— 训练好的浮点权重（embedding、attention / MLP 权重、三组
  RMSNorm gain）。用参考代码里的 `q()` 量化到 Q5.11；ROM 的内容与排布由你自行生成
  （本仓不提供预打包的 `.hex`）。

参考代码定义"算什么、怎么量化"，不定义"电路怎么搭"。请阅读参考代码以掌握精确数值
行为（定点取整、饱和、除法、查表等每一处细节）。

## 2. 功能范围

一个 transformer 解码步，顺序为：

embed(token + position) → RMSNorm → 因果多头注意力（+ 残差）→ RMSNorm →
MLP(ReLU)（+ 残差）→ 终 RMSNorm → LM head → 采样。

精确算法以参考代码为准。模型维度：

- VOCAB = 27，N_EMBED = 24，N_HEAD = 4，HEAD_DIM = 6，MLP_HID = 96，BLOCK = 16，单层。

**增量解码与持久 KV：** 每次 `start` 处理位置 `pos_in` 上的一个新 token，把它的 K/V
写入缓存，并对前缀 0..`pos_in` 做注意力；K/V 缓存必须跨调用保留（host 每步只喂一个新
token，不重喂历史）。

**采样：** `sample_mode=0` 贪心 argmax；`sample_mode=1` 温度 softmax，使用 host 提供
的确定性 seeded PRNG（`rng_in` → `rng_out` 回喂，数值行为见参考代码），温度以
`inv_temp`（Q5.11）给出。

**不做：** 参数化 / 可配置（单层、维度硬编码即可）。

## 3. 接口与集成契约

顶层 microgpt_core 有 12 个端口（8 输入，4 输出）：

| Signal | Dir | Width | Notes |
|--|--|--|--|
| `clk` | in | 1 | 单时钟 |
| `resetn` | in | 1 | 同步低有效 |
| `start` | in | 1 | 启动一步 token |
| `token_in` | in | 5 | 新 token |
| `pos_in` | in | 5 | 绝对位置 0..BLOCK−1 |
| `sample_mode` | in | 1 | 贪心 / 采样 |
| `inv_temp` | in | signed 16 | 1/温度，Q5.11 |
| `rng_in` | in | 32 | LCG 状态入 |
| `busy` | out | 1 | |
| `done` | out | 1 | 结果有效 |
| `next_token` | out | 5 | |
| `rng_out` | out | 32 | 推进后的 LCG 状态 |

**每步协议：** host 拉高 `start` 并给出该步输入；核置 `busy`；完成时置 `done`，此时
`next_token` / `rng_out` 有效。host 捕获 `next_token` 作为下一步 `token_in`，递增
`pos_in`，把 `rng_out` 回喂作 `rng_in`，直到 `next_token == 0`（分隔符）终止。

## 4. 约束

- **定点：** Q5.11 signed-16 数据通路；取整、饱和与累加器宽度等数值语义以参考代码为准。
- **时钟与复位：** 单一时钟域；`resetn` 同步、低有效。
- **KV 缓存不得被 `resetn` 清除**（增量解码语义要求跨调用保留）。

## 5. 微架构：你的职责

指令集 / 调度、内存布局与地址映射、模块划分、流水线与每-token 周期数，均由你设计。
本文不提供、也不约束（约束仅来自 §3 接口与 §6 PPA）。

## 6. PPA 目标

**性能：**

- 时序：SDC 时钟周期 12.5 ns（80 MHz）；综合与 STA 后无 setup/hold 违例。
- 吞吐：每 token step（`start` → `done`）最优 ≤ 1,156 周期；最长上下文
  （`pos_in` = BLOCK−1）≤ 1,500 周期；整名平均 ≥ 60,600 tok/s @ 80 MHz。

**面积：**

- 目标工艺只有标准单元库（无 memory 宏与宏模型），权重 ROM 与 KV 缓存均以标准单元实现。
- 逻辑 ≤ 0.45M NAND2 等效门，ROM 与 KV 计入；NAND2 等效门 = Total cell area ÷ 库 NAND2X1 面积。
- 片上工作存储 ≤ 16 Kbit（含持久 KV 缓存），约束比特数。

**功耗：** 无目标（功能设计）。

## 7. 验收与签核

**端到端（黑盒，唯一功能判据）：** 按 §3 协议驱动核，逐 token 生成的序列必须逐一
等于——

- 贪心（`sample_mode=0`，`rng_in=0`）：`[1, 12, 1, 25, 1]` = "alaya"，随后 token 0
  终止。
- 采样（`sample_mode=1`，seed=2，T=0.7 即 `inv_temp=2926`）：
  `[18, 15, 19, 16, 8, 15, 4]` = "rosphod"，随后 token 0 终止。

"位精确"定义为：RTL 与 `reference/fixedpoint.py` 在 Q5.11 下逐比特一致。参考模型可
同时作为各单元的自检 oracle（可选，用于定位）。

**其他验收门：**

- RTL 用 Verilog-2001，整体可综合；空 stub、blackbox、`initial` 加载的存储数组视为未实现。
- UVM testbench 功能验证，行 / 条件 / 状态机 / 翻转覆盖率均 > 90%。
- lint / CDC clean（0 Error、0 Warning）。
