# Atrium PA Capture

Menu-bar Mac app that records both sides of a meeting and uploads the
audio to Atrium PA for transcription.

- [Releases](https://github.com/brendanbank/atrium-pa-mac/releases)
- Update feed: [`appcast.xml`](appcast.xml)

The feed is consumed by the app itself. Each update is signed with an
EdDSA key that never leaves the build machine, so a compromised host
cannot serve a modified build — the app refuses anything it cannot
verify.
