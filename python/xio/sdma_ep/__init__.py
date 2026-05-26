"""
SDMA Endpoint Python Bindings for ROCm-XIO

Provides host-initiated SDMA operations for AMD Instinct GPUs.
Drop-in replacement for ext/shader_sdma/anvil.
"""

from .sdma_ep_py import *

__all__ = [
    'SdmaQueuePythonDeviceCtx',
    'Tile',
    'QUEUE_DEVICE_CTX_SIZE',
    'COPY_LINEAR_COMMAND_BYTES',
    'COPY_LINEAR_SUB_WINDOW_COMMAND_BYTES',
    'ATOMIC_COMMAND_BYTES',
    'SDMA_QUEUE_SIZE',
    # Module-level functions
    'init',
    'shutdown',
    'create_queue',
    'create_host_queue',
    'get_queue_device_ctx',
    'put',
    'put_signal',
    'put_tile',
    'put_tiles',
    'put_tile_signal',
    'put_tiles_signal',
    'wait_flag_then_put',
    'wait_flag_then_put_tile',
    'wait_flag_then_put_tiles',
    'signal',
    'timestamp',
    'quiet',
]

__version__ = '0.1.0'
