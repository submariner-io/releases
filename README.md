# Releases

<!-- markdownlint-disable line-length -->
[![CII Best Practices](https://bestpractices.coreinfrastructure.org/projects/4865/badge)](https://bestpractices.coreinfrastructure.org/projects/4865)
[![Release](https://github.com/submariner-io/releases/workflows/Release%20the%20Target%20Release/badge.svg)](https://github.com/submariner-io/releases/actions?query=workflow%3A%22Release+the+Target+Release%22)
[![Periodic](https://github.com/submariner-io/releases/workflows/Periodic/badge.svg)](https://github.com/submariner-io/releases/actions?query=workflow%3APeriodic)
<!-- markdownlint-enable line-length -->

To create or advance a release, simply run `make release VERSION='$semver'`, e.g.

* `make release VERSION='1.2.3'
* `make release VERSION='1.2.3-rc1'

Make sure you set the `GITHUB_TOKEN` environment variable to a [Personal Access Token](https://github.com/settings/tokens) which has
at least `public_repo` access to your repository.
