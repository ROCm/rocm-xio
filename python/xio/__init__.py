"""
ROCm XIO - GPU-Initiated I/O Library

Provides Python bindings for ROCm XIO endpoints:
- sdma_ep: SDMA (System DMA) endpoint for host-initiated DMA operations
- rdma_ep: GPU-initiated RDMA endpoint (present when built with a GDA provider, e.g. GDA_MLX5=ON)
"""

from . import sdma_ep

try:
    from . import rdma_ep
except ImportError:  # built without an RDMA provider
    rdma_ep = None

__all__ = ['sdma_ep', 'rdma_ep']
__version__ = '0.1.0'
