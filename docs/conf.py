# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

"""Sphinx configuration for rocm-xio documentation."""

project = "rocm-xio"
author = "Advanced Micro Devices, Inc."
copyright = (
    "2024-2026 Advanced Micro Devices, Inc. "
    "All rights reserved."
)

version = "0.0.1"
release = version

# -- Extensions --------------------------------------------------

extensions = [
    "breathe",
]

# -- Breathe (Doxygen XML import) --------------------------------

breathe_projects = {
    "rocm-xio": "@BREATHE_DOC_XML_DIR@",
}
breathe_default_project = "rocm-xio"
breathe_default_members = ("members",)

# -- General -----------------------------------------------------

exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]
templates_path = []

# Breathe cannot parse anonymous unions inside structs
# (rdma_wqe, rdma_cqe). Suppress the resulting warnings.
suppress_warnings = [
    "cpp.duplicate_declaration",
]

# -- HTML output -------------------------------------------------

html_theme = "sphinx_book_theme"
html_theme_options = {
    "repository_url": (
        "https://github.com/ROCm/rocm-xio"
    ),
    "use_repository_button": True,
    "show_toc_level": 2,
}
html_title = f"rocm-xio {version}"
html_static_path = []
