#!/bin/bash
# handoff/refs/fetch.sh — 按 sources.lock 复现落盘 [A] 类标准原文, 并校验 sha256(定死)。
# 开源项(RISC-V)自动下载+校验; 许可受限项(AXI)仅提示手动自备。
set -u
cd "$(dirname "$0")"

fetch() {  # name url sha256
  local f="$1" url="$2" want="$3"
  if [ -f "$f" ] && [ "$(sha256sum "$f" | awk '{print $1}')" = "$want" ]; then
    echo "OK(cached)  $f"; return
  fi
  echo "downloading $f ..."
  curl -sSL -m 300 -o "$f" "$url" || { echo "FAIL download $f"; return 1; }
  local got; got=$(sha256sum "$f" | awk '{print $1}')
  if [ "$got" = "$want" ]; then echo "OK          $f"; else
    echo "SHA MISMATCH $f"; echo "  want $want"; echo "  got  $got"; return 1; fi
}

BASE="https://github.com/riscv/riscv-isa-manual/releases/download/riscv-isa-release-74010d0-2026-07-23"
fetch riscv-spec.html       "$BASE/riscv-spec.html" \
      0905432edeaf44ab3ae8fc48acde40e12ccf7842357b54c198e50128039f249b
fetch riscv-norm-rules.json "$BASE/norm-rules.json" \
      2b29d0e84732586f187e6435a679271fc142edf38af0269c93ce580888529d52

echo "----"
# SiFive TileLink 1.8.0 (© SiFive, All rights reserved): 公开 GitHub 镜像可脚本直取(非 AXI 那种交互门控);
# 本地自用、**不入仓**(.gitignore 排除 *.pdf/*.txt)。操作性真源用已入仓的 OpenTitan TL-UL, 本份仅辅助。
fetch tilelink-1.8.0.pdf \
      "https://raw.githubusercontent.com/chipsalliance/omnixtend/86894139fdb2e76de964cc588aa5fcfb293060d6/OmniXtend-1.0.3/spec/TileLink-1.8.0.pdf" \
      61201ed478d7985bfc07d422e677110ec416cb9757ac519caca44dba8bd1ee1f
command -v pdftotext >/dev/null && [ ! -f tilelink-1.8.0.txt ] && \
  pdftotext -layout tilelink-1.8.0.pdf tilelink-1.8.0.txt && echo "  -> tilelink-1.8.0.txt (本地, 不入仓)"

echo "----"
AXI_PDF=IHI0022L_amba_axi_protocol_spec.pdf
AXI_TXT=IHI0022L_amba_axi_protocol_spec.txt
AXI_SHA=20aa5f946df5fa97053689d705959b1ef6a90a88f845fa3b686a53311f680ac1
if [ -f "$AXI_PDF" ]; then
  got=$(sha256sum "$AXI_PDF" | awk '{print $1}')
  if [ "$got" = "$AXI_SHA" ]; then echo "OK(local)   $AXI_PDF  (sha256 匹配 IHI 0022 Issue L)"
  else echo "SHA MISMATCH $AXI_PDF"; echo "  want $AXI_SHA"; echo "  got  $got"; fi
  command -v pdftotext >/dev/null && [ ! -f "$AXI_TXT" ] && \
    pdftotext -layout "$AXI_PDF" "$AXI_TXT" && echo "  -> $AXI_TXT (agent/验证读这份, 不解析 PDF)"
else
  echo "MANUAL      $AXI_PDF 缺失 — ARM 许可门控, 从 sources.lock 的 url 手动下载放此(不入仓);"
  echo "            agent/验证读 pdftotext 转出的 TXT。所需特性已在 brainstorm §5.2.1 钉死。"
fi
