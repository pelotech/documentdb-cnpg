# Changelog

## 1.0.0 (2026-07-21)


### Features

* build orchestrator; end-to-end build + verify green ([c7b7d13](https://github.com/pelotech/documentdb-cnpg/commit/c7b7d13fe5c56cf7677f3b9beb1dd34a29d8447d))
* compute /system dependency closure (extension deps minus core libs) ([ce549d1](https://github.com/pelotech/documentdb-cnpg/commit/ce549d1fd2fbd95fefe587d6417a16679c1a02bb))
* publish tagged postgresql and extension images ([#2](https://github.com/pelotech/documentdb-cnpg/issues/2)) ([930e419](https://github.com/pelotech/documentdb-cnpg/commit/930e4195c8495deeb066665f2d7954e06a07971a))
* stage A - build documentdb extension .deb against ICU 77 ([ea456b6](https://github.com/pelotech/documentdb-cnpg/commit/ea456b60197e9951e32742bb2fec3fdf64695c07))
* stage B - package ICU-77 extension as CNPG ImageVolume image ([42c2c43](https://github.com/pelotech/documentdb-cnpg/commit/42c2c43f2ac741f3b1fa3e6a965d05754be0a450))
* support PG17/PG18 engine and PG18 ImageVolume images ([#1](https://github.com/pelotech/documentdb-cnpg/issues/1)) ([719fac3](https://github.com/pelotech/documentdb-cnpg/commit/719fac3c9ffd73d92335267ff4f56e3fbba0d548))


### Bug Fixes

* **stage-a:** make ICU-77 guard robust to pipefail SIGPIPE ([755a57d](https://github.com/pelotech/documentdb-cnpg/commit/755a57d76aa351ebbc11b552f3bbc48467927cf4))
* **verify:** make the acceptance gate pass end-to-end on the hardened base ([b09b9bd](https://github.com/pelotech/documentdb-cnpg/commit/b09b9bd6a0a971bf45a92b2d8c8e9cbf7cbabbb6))


### Refactors

* rename image repo to documentdb-cnpg ([#4](https://github.com/pelotech/documentdb-cnpg/issues/4)) ([a5206fb](https://github.com/pelotech/documentdb-cnpg/commit/a5206fb82af4909cc7f5a1425287d0bfacbfcba1))


### CI

* map MINIMUS_REGISTRY secret to env (secrets context is invalid in step if:) ([dc173ad](https://github.com/pelotech/documentdb-cnpg/commit/dc173ad427e3c41641096dcc3fc2123c6a429279))
* per-arch build with ICU-drift and glibc guards, verify-before-publish ([25c115d](https://github.com/pelotech/documentdb-cnpg/commit/25c115df08dcb2a69f037f0c5515b521a35c4060))


### Tests

* self-contained CNPG load + CREATE EXTENSION verification gate ([2321ca9](https://github.com/pelotech/documentdb-cnpg/commit/2321ca9cd2fa6de54e7c9916834bb25375cc3497))
