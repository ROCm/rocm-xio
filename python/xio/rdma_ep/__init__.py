"""GPU-initiated RDMA: one reliable-connected QP per ``Endpoint``."""

from .rdma_ep_py import DEVICE_CTX_WORDS, Endpoint

__all__ = ["DEVICE_CTX_WORDS", "Endpoint"]
