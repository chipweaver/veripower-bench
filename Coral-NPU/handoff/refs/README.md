# handoff/refs — [A] 类标准的落盘真源

目的：让开发**不依赖模型的训练知识**——[A] 类标准的原文在此落盘、版本钉死，
开发与验证**读原文、逐条引用**，从而可复现、可审计、与模型/工具无关（老手新手皆可）。

## 机制
- `sources.lock`：每份标准的 id/版本/URL/**sha256**/许可/是否入仓/本地文件（版本定死）。
- `fetch.sh`：按 lock 复现下载并**校验 sha256**（是"定死那一版"，不是"最新"）。
- 落盘优先**文本形态**（HTML/JSON/TXT），非 PDF：弱模型/纯文本工具（grep/diff）皆可读、可按条引用、可 diff。
  （PDF 虽可用 `pdftotext`/多模态读，但抽取不确定、不利引用，仅作出处存证。）

## 用法
```
bash handoff/refs/fetch.sh      # 拉取并校验 RISC-V 原文; 提示 AXI 手动自备
```
- **RISC-V**（开源 CC）：`riscv-spec.html`（RV-U/RV-P/Zbb 统一手册）+ `riscv-norm-rules.json`（机读规范规则，便于逐条引用）。**已直接入仓（vendored）**：开发/验证直接读这两份，**无需跑 `fetch.sh`、无需网络、不依赖 agent 拉取**；`fetch.sh` 退化为"完整性自检 + 全新机器 bootstrap"。
- **AXI**（ARM 版权，**不得再分发**）：不入仓；开发者按 `sources.lock` 的 URL 本地自备
  `arm-axi-ihi0022.pdf`，`fetch.sh` 会用 `pdftotext -layout` 转出 `arm-axi-ihi0022.txt`；
  **agent/验证读该 TXT、不直接解析 PDF**（避免不同工具/模型抽取不一致）。实际所需特性已在
  `../brainstorm.md` §5.2.1「AXI 特性档」钉死（含 §A5 id 回显）。
  **AXI 与 RISC-V 同为真源、地位等价**（差别仅"是否入仓"，与模型无关性正交）：AXI 文本为
  **开发前置硬门（fail-closed）**——未本地自备则不得开工，**绝不退回训练记忆补 AXI**；
  且 `sources.lock` 的 AXI **issue + sha256 须在自备时回填**（当前 PENDING），方与 RISC-V
  同等做到版本钉死、可复现校验。

## 引用纪律（对应 brainstorm §约定 的 [A] 要求）
- 每条实现/检查项标注遵循的具体条款（如 `RISC-V spec §… / 规则ID`、`ARM IHI 0022 §A5`）。
- **无来源引用的行为 = 缺陷线索**（很可能来自训练脑补，须补引用或改正）。

## 入仓策略（见 `.gitignore`）
- **入仓**：`sources.lock`、`fetch.sh`、本 README；**+ RISC-V 原文 `riscv-spec.html`、`riscv-norm-rules.json`**（CC 开放、可再分发）——作**自包含基线**：clone 即有、直接读，不依赖 fetch/网络/agent 跑脚本；sha256 仍作完整性锚点。
- **永不入仓**：AXI `*.pdf` / `*.txt`（ARM 许可禁止再分发）——按 `sources.lock` 本地自备。
  → RISC-V 自包含、AXI 许可干净；两者都由 sha256 定死那一版。
