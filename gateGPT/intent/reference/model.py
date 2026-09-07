# Inference-golden config for the microgpt_core reproduction. Only ModelConfig is
# needed by tools/fixedpoint.py (the Q5.11 golden). The full PyTorch training model
# (gateGPT/tools/model.py) is out of scope per the design Non-goals — training and
# weight generation are fixed external inputs (weights.npz).
from dataclasses import dataclass

@dataclass
class ModelConfig:
    vocab_size: int = 27      # '.' + a..z
    block_size: int = 16      # max context (also max generated length)
    n_embed: int = 24         # model width
    n_head: int = 4
    head_dim: int = 6         # n_head * head_dim == n_embed
    mlp_hidden: int = 96      # MLP inner width
    n_layer: int = 1
