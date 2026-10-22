"""GPU-initiated RDMA: one reliable-connected QP per ``Endpoint``."""

from .rdma_ep_py import Endpoint

__all__ = ["Endpoint"]
