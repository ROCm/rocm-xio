# Configuration file for the Sphinx documentation builder.
#
# This file only contains a selection of the most common options. For a full
# list see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

import re

'''
html_theme is usually unchanged (rocm_docs_theme).
flavor defines the site header display, select the flavor for the corresponding portals
flavor options: rocm, rocm-docs-home, rocm-blogs, rocm-ds, instinct, ai-developer-hub, local, generic
'''
html_theme = "rocm_docs_theme"
html_theme_options = {
    "flavor": "generic",
    "header_title": "ROCm™ XIO (Beta) 0.1.0",
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

# Dynamically extract component version
#with open('../CMakeLists.txt', encoding='utf-8') as f:
#    pattern = r'.*\brocm_setup_version\(VERSION\s+([0-9.]+)[^0-9.]+' # Update according to each component's CMakeLists.txt
#    match = re.search(pattern,
#                      f.read())
#    if not match:
#        raise ValueError("VERSION not found!")
version_number = "0.1.0"

# for PDF output on Read the Docs
project = "ROCm™ XIO (Beta)"
author = "Advanced Micro Devices, Inc."
copyright = "Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved."
version = version_number
release = version_number

external_toc_path = "./sphinx/_toc.yml" # Defines Table of Content structure definition path

# Add more additional package accordingly
extensions = [
    "breathe",
    "rocm_docs", 

] 

breathe_projects = {
    "rocm-xio": "@BREATHE_DOC_XML_DIR@",
}
breathe_default_project = "rocm-xio"
breathe_default_members = ("members",)

exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]
templates_path = []

# Breathe cannot parse anonymous unions inside structs
# (rdma_wqe, rdma_cqe). Suppress the resulting warnings.
suppress_warnings = [
    "cpp.duplicate_declaration",
]

html_title = f"{project} {version_number} documentation"

external_projects_current_project = "ROCm™ XIO (Beta) 0.1.0"
