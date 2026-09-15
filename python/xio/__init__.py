"""
ROCm XIO - GPU-Initiated I/O Library

Provides Python bindings for ROCm XIO endpoints:
- sdma_ep: SDMA (System DMA) endpoint for host-initiated DMA operations
"""

from . import sdma_ep

__all__ = ['sdma_ep']
__version__ = '0.1.0'
