"""
SDMA Endpoint Python Bindings for ROCm-XIO

Provides host-initiated SDMA operations for AMD Instinct GPUs.
Drop-in replacement for ext/shader_sdma/anvil.
"""

from .sdma_ep_py import (
    AnvilLib,
    SdmaQueuePythonDeviceCtx,
    Tile,
    QUEUE_DEVICE_CTX_SIZE,
    SDMA_PKT_COPY_LINEAR_BYTES,
    SDMA_PKT_LINEAR_SUB_WINDOW_BYTES,
    SDMA_PKT_ATOMIC_BYTES,
    SDMA_QUEUE_SIZE,
)

__all__ = [
    'AnvilLib',
    'SdmaQueuePythonDeviceCtx',
    'Tile',
    'QUEUE_DEVICE_CTX_SIZE',
    'SDMA_PKT_COPY_LINEAR_BYTES',
    'SDMA_PKT_LINEAR_SUB_WINDOW_BYTES',
    'SDMA_PKT_ATOMIC_BYTES',
    'SDMA_QUEUE_SIZE',
]

__version__ = '0.1.0'
