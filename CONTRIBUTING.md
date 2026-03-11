# Contributing to rocm-xio

Thank you for contributing! This guide outlines the development workflow,
contribution standards, and best practices when working on rocm-xio.

## Development Setup

Install the dependencies listed in [INSTALL.md](INSTALL.md) and build the
project. Run the test suite with `ctest .` before submitting changes.

## Branching Model

The main development trunk of rocm-xio is the `main` branch.

rocm-xio generally uses trunk-based development, where feature branches are
intended to be relatively short-lived. When necessary, feature branches will
be created and prefixed with `feature/`. These feature branches will be
deleted after the feature has been merged to `main`. Any feature branches
which are not merged to `main`, but should be kept around for posterity,
will be renamed `feature` --> `inactive`.

External developers must use forks for development. You will sometimes see
branches from AMD staff named `<category>/<user>/<description>`. These will
be very short-lived.

### Release branches

Releases are tagged `vX.Y.Z`, where `X`, `Y`, and `Z` are the major, minor,
and patch versions of the release.

Releases occur from `main`. Upon release, the tag is created and the minor
version number is bumped. The major version number will only be bumped on
`main` when making an API/ABI-breaking change.

Release branches are created retroactively and only when it is necessary to
bugfix supported versions of the library. Bugfixing should take place on
`main` and be cherry-picked to any branches that are being maintained.

## Pull Requests

We welcome pull requests from outside contributors. Pull requests must pass
our CI and be approved by at least one code owner. Outside contributors
should fully fill out the PR template for non-trivial PRs.

Please also ensure that your code complies with this project's coding style,
as detailed in [STYLEGUIDE.md](STYLEGUIDE.md).

## Issue Reporting

* Non-security issues should be reported as GitHub issues
* Security issues should be reported as directed in [SECURITY.md](SECURITY.md)
* Feature requests should be made using GitHub discussions
