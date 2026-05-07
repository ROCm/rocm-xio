# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Configuration file for the Sphinx documentation builder.
#
# This file only contains a selection of the most common options. For a full
# list see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

import os
import re
from pathlib import Path

_raw_version = "@ROCM_XIO_LIBRARY_VERSION@"
if _raw_version.startswith("@"):
    _cmakelists = Path(__file__).resolve().parent.parent / "CMakeLists.txt"
    _cmake_txt = _cmakelists.read_text(encoding="utf-8")
    _maj = re.search(r"set\(ROCM_XIO_LIBRARY_MAJOR\s+(\d+)\)", _cmake_txt)
    _min = re.search(r"set\(ROCM_XIO_LIBRARY_MINOR\s+(\d+)\)", _cmake_txt)
    _pat = re.search(r"set\(ROCM_XIO_LIBRARY_PATCH\s+(\d+)\)", _cmake_txt)
    if _maj and _min and _pat:
        version_number = (
            f"{_maj.group(1)}.{_min.group(1)}.{_pat.group(1)}"
        )
    else:
        version_number = "0.0.0"
else:
    version_number = _raw_version

'''
html_theme is usually unchanged (rocm_docs_theme).
flavor defines the site header display, select the flavor for the corresponding portals
flavor options: rocm, rocm-docs-home, rocm-blogs, rocm-ds, instinct, ai-developer-hub, local, generic
'''
html_theme = "rocm_docs_theme"
html_theme_options = {
    "flavor": "generic",
    "header_title": f"ROCm™ XIO (Beta) {version_number}",
    "header_link": "https://github.com/ROCm/rocm-xio",
    "nav_secondary_items": {
        "GitHub": "https://github.com/ROCm/rocm-xio",
        "Community": "https://github.com/ROCm/rocm-xio/wiki",
        "Blogs": "https://rocm.blogs.amd.com/",
        "ROCm Developer Hub": "https://www.amd.com/en/developer/resources/rocm-hub.html",
        "Instinct™ Docs": "https://instinct.docs.amd.com/",
        "Infinity Hub": "https://www.amd.com/en/developer/resources/infinity-hub.html",
        "Support": "https://github.com/ROCm/rocm-xio/issues/new/choose",
    },
    "link_main_doc": False,

}


# This section turns on/off article info
setting_all_article_info = True
all_article_info_os = ["linux"]
all_article_info_author = ""

# for PDF output on Read the Docs
project = "ROCm XIO (Beta)"
author = "Advanced Micro Devices, Inc."
copyright = "Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved."
version = version_number
release = version_number

# Defines Table of Content structure definition path.
external_toc_path = "./sphinx/_toc.yml"

extensions = [
    "rocm_docs",
    "rocm_docs.doxygen",
]

# Defaults are source-tree paths for Read the Docs. CMake docs builds set
# ROCM_XIO_* overrides so generated Doxygen files live under the build tree.
doxygen_root = os.environ.get("ROCM_XIO_DOXYGEN_ROOT", "doxygen")
doxyfile = os.environ.get("ROCM_XIO_DOXYFILE", "doxygen/Doxyfile.in")
doxygen_project = {
    "name": "ROCm XIO",
    "path": os.environ.get("ROCM_XIO_DOXYGEN_XML", "doxygen/xml"),
}
doxysphinx_enabled = False

external_projects = []
# Standalone XIO is not in rocm-docs-core's bundled projects.yaml yet; use a
# known id so intersphinx / theme logic does not warn on every build.
external_projects_current_project = "hip"
external_projects_remote_repository = ""

cpp_id_attributes = [
    "__global__",
    "__device__",
    "__host__",
    "__forceinline__",
    "__restrict__",
    "static",
]
cpp_paren_attributes = ["__declspec"]

exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]
templates_path = []

# Breathe (pulled in by rocm_docs.doxygen) warns on duplicate declarations for
# anonymous unions in some structs (e.g. rdma_wqe, rdma_cqe).
suppress_warnings = [
    "cpp.duplicate_declaration",
]

html_title = f"{project} {version_number} documentation"
