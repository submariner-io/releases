---
name: Release Tracker
about: Release Tracker
title: 'Release <x.y.z>'
labels: release-tracker

---

<!--
Fill in the actual release version.
If the schedule release date is known, fill the actual date.
-->

**Scheduled release date: TBD**

This is a tracker to aggregate issues that should be part of <x.y.z>. 
Please add specific Issues or PRs prefixed with the "Depends on" keyword 
(and remember that PRs need to be backported to the release-<x.y> branch).

Make sure to follow the manual steps listed below before starting the release process.

### Manual Steps 

For detailed information regarding each step, please check: https://submariner.io/development/building-testing/ci-maintenance/
- [ ] Custom GitHub Actions
- [ ] GitHub Actions
- [ ] Kubernetes Versions
- [ ] (For branches before 0.16) Shipyard Base Image Software
- [ ] Shipyard Linting Image Software
- [ ] (For rc0 release only) Start release x+1-m0 once the rc0 release is done

