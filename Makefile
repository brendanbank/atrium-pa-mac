# Atrium PA Capture — build, bundle, sign, run.
#
# `swift build` alone is NOT enough to get a working app. A bare binary
# cannot hold the audio-capture TCC grant, so the process tap silently
# delivers buffers of zeroes. The bundle is load-bearing; see README.

APP_NAME    := AtriumMac
BUNDLE_NAME := Atrium PA Capture
BUNDLE      := build/$(BUNDLE_NAME).app
CONFIG      := release
BIN         := .build/$(CONFIG)/$(APP_NAME)

# Signing identity.
#
# Ad-hoc (`-`) works, but its designated requirement is the *binary's
# hash*:
#
#     designated => cdhash H"f4696d..."
#
# which changes on every build. macOS therefore treats each `make` as a
# brand-new application: the microphone grant resets to notDetermined,
# the notification permission resets, and every keychain item the app
# created starts demanding the login password again — twenty times in an
# afternoon of rebuilds.
#
# A self-signed certificate fixes all three at once, because its
# designated requirement is the bundle id plus the certificate:
#
#     designated => identifier "com.atrium-mac.capture"
#                   and certificate leaf = H"2667..."
#
# That is stable across rebuilds. The certificate does not need to be
# *trusted* — codesign signs with it regardless, and nothing here is
# distributed — so no admin password is needed to create one.
#
#     make signing-identity     # once, then never again
#
# Falls back to ad-hoc when no such certificate exists, so a fresh
# checkout still builds with no setup.
SIGNING_CN := Atrium PA Capture (local dev)
CODESIGN_IDENTITY ?= $(shell security find-identity -p codesigning 2>/dev/null \
	| grep -q "$(SIGNING_CN)" && echo "$(SIGNING_CN)" || echo -)

# Hardened runtime, but only for a real Developer ID.
#
# Notarization requires it, and it requires the microphone entitlement —
# without which a hardened build records silence and does not say why.
# It is deliberately *not* applied to the self-signed development
# identity: that path works today, and turning on a different runtime
# for it would change the one configuration this app is known to capture
# audio in, for no benefit until there is something to notarize.
ifneq (,$(findstring Developer ID,$(CODESIGN_IDENTITY)))
SIGN_FLAGS := --options runtime --entitlements Resources/AtriumMac.entitlements
endif

VERSION := $(shell plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
DMG     := build/$(BUNDLE_NAME) $(VERSION).dmg
DMG_ROOT := build/dmg

# Notarization credentials, stored once with:
#
#   xcrun notarytool store-credentials atrium-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific>
#
NOTARY_PROFILE ?= atrium-notary

.PHONY: all build bundle sign run clean probes verify test test-live signing-identity trust-keychain icon install dmg notarize

all: bundle

build:
	swift build -c $(CONFIG)

bundle: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	@cp "$(BIN)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(BUNDLE)/Contents/PkgInfo"
	@$(MAKE) --no-print-directory sign
	@echo "built $(BUNDLE)"

sign:
	@codesign --force --sign "$(CODESIGN_IDENTITY)" --timestamp=none $(SIGN_FLAGS) "$(BUNDLE)"
	@codesign -dv "$(BUNDLE)" 2>&1 | grep -E 'Identifier|Info.plist' || true

# Launch through LaunchServices, NOT by exec'ing the binary directly.
# TCC attributes a directly-exec'd binary to the parent terminal, which
# is how you end up debugging a recorder that captures pure silence.
run: bundle
	@open "$(BUNDLE)"
	@echo "launched — look for the waveform icon in the menu bar"

# Confirm the bundle is capable of holding a TCC grant at all.
verify: bundle
	@echo "--- signature ---"
	@codesign -dv "$(BUNDLE)" 2>&1 | grep -E 'Identifier|Format|Info.plist'
	@echo "--- Info.plist usage strings ---"
	@plutil -extract NSAudioCaptureUsageDescription raw "$(BUNDLE)/Contents/Info.plist"
	@plutil -extract NSMicrophoneUsageDescription raw "$(BUNDLE)/Contents/Info.plist"

# A disk image to hand to somebody else.
#
# The window contains the app and a symlink to /Applications, which is
# the drag-and-drop install every Mac user already knows. `hdiutil` and
# `ln` do the whole job — no `create-dmg`, no Finder AppleScript to
# position icons, because this project builds with the Command Line
# Tools alone and a background image is not worth a dependency that can
# fail on somebody else's machine.
#
# **Until this is notarized, a Mac that downloads it will refuse to open
# it.** Gatekeeper quarantines anything that arrives from elsewhere, and
# on macOS 15+ the Control-click bypass is gone — the recipient has to go
# to System Settings › Privacy & Security and press Open Anyway, for
# every release. `make notarize` is what removes that, and it needs the
# Developer ID.
dmg: bundle
	@rm -rf "$(DMG_ROOT)" "$(DMG)"
	@mkdir -p "$(DMG_ROOT)"
	@cp -R "$(BUNDLE)" "$(DMG_ROOT)/"
	@ln -s /Applications "$(DMG_ROOT)/Applications"
	@hdiutil create -volname "$(BUNDLE_NAME)" -srcfolder "$(DMG_ROOT)" \
		-ov -format UDZO -quiet "$(DMG)"
	@rm -rf "$(DMG_ROOT)"
	@if [ "$(CODESIGN_IDENTITY)" != "-" ]; then \
		codesign --force --sign "$(CODESIGN_IDENTITY)" "$(DMG)" && \
		echo "signed the image with $(CODESIGN_IDENTITY)"; \
	fi
	@echo "built $(DMG)"
	@echo "   drag the app onto the Applications link to install"
	@if ! echo "$(CODESIGN_IDENTITY)" | grep -q "Developer ID"; then \
		echo "   NOT notarized — another Mac will refuse to open it."; \
		echo "   See 'make notarize' once you have a Developer ID."; \
	fi

# Notarize the image and staple the ticket, so it opens anywhere.
#
# Needs a Developer ID *and* a hardened-runtime build — both of which
# happen automatically once `security find-identity` reports one, see
# CODESIGN_IDENTITY and SIGN_FLAGS above.
#
# Stapling matters: without it the first launch needs the network to
# check, and a laptop opening this on a train would be refused.
notarize: dmg
	@echo "submitting $(DMG) — this takes a few minutes"
	@xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple "$(DMG)"
	@xcrun stapler validate "$(DMG)"
	@spctl --assess --type open --context context:primary-signature -v "$(DMG)" || true
	@echo "notarized and stapled — this image opens on any Mac"

# Install into /Applications, which is where a Mac app lives.
#
# `make run` launches out of ./build, which is fine while working on it
# and wrong for using it: the path is inside a git worktree, so the app
# people actually rely on sits somewhere that gets moved, rebuilt or
# deleted — and two checkouts means two copies and no way to tell which
# one is running.
#
# The signing identity is what TCC keys on, not the path, so grants
# survive the move. The login item does not: `SMAppService` registered
# the old location, so it is re-registered from the new one on next
# launch via Settings.
INSTALL_DIR ?= /Applications
install: bundle
	@rm -rf "$(INSTALL_DIR)/$(BUNDLE_NAME).app"
	@cp -R "$(BUNDLE)" "$(INSTALL_DIR)/"
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister 		-f "$(INSTALL_DIR)/$(BUNDLE_NAME).app"
	@echo "installed $(INSTALL_DIR)/$(BUNDLE_NAME).app"

# Redraw the app icon. Committed output — this is not a build step.
#
# `Resources/AppIcon.icns` is in the repository, so a fresh checkout
# builds without running this. The generator is here because a binary
# blob with no source is a blob nobody can change: the mark comes from
# atrium's own `frontend/public/logo.svg`, and if that ever changes this
# is where to follow it.
#
# CoreGraphics rather than librsvg or ImageMagick, so it needs nothing
# this project does not already need.
icon:
	@rm -rf build/AppIcon.iconset
	@swift Tools/make-icon.swift build/AppIcon.iconset >/dev/null
	@iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

# One-time: mint a stable self-signed code-signing certificate.
#
# Without it every rebuild is a new application to macOS — see the note
# on CODESIGN_IDENTITY above. Safe to re-run; it refuses if one exists.
signing-identity:
	@if security find-identity -p codesigning 2>/dev/null | grep -q "$(SIGNING_CN)"; then \
		echo "already have '$(SIGNING_CN)'"; \
	else \
		set -e; \
		tmp=$$(mktemp -d); \
		printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=v3\n[dn]\nCN=%s\n[v3]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$(SIGNING_CN)" > $$tmp/cnf; \
		openssl req -x509 -newkey rsa:2048 -nodes -keyout $$tmp/key.pem \
			-out $$tmp/cert.pem -days 3650 -config $$tmp/cnf 2>/dev/null; \
		openssl pkcs12 -export -legacy -out $$tmp/b.p12 -inkey $$tmp/key.pem \
			-in $$tmp/cert.pem -passout pass:atrium 2>/dev/null; \
		security import $$tmp/b.p12 -k $$HOME/Library/Keychains/login.keychain-db \
			-P atrium -T /usr/bin/codesign -A; \
		rm -rf $$tmp; \
		echo "created '$(SIGNING_CN)' — rebuilds now keep their TCC grants"; \
	fi

# One-time: stop macOS prompting for the login password on every run.
#
# Two separate mechanisms, both of which produce the same dialog and
# neither of which is the ACL fixed in Keychain.swift:
#
#  1. The signing key. `codesign` reads its private key from the login
#     keychain on every build.
#  2. The app's own items. A generic-password item carries a *partition
#     list* naming which code may read it, and an app signed with a
#     self-signed certificate has no team identifier to match against —
#     so securityd reports "ACL partition mismatch" and asks. The prompt
#     is app-modal, which is worse than it sounds: it blocks the app's
#     main thread, so the menu and windows stop responding until it is
#     answered.
#
# Both are fixed by widening the partition list, which needs the login
# password once. It is prompted for interactively rather than passed on
# a command line, so it never reaches the shell history or the process
# table.
trust-keychain:
	@echo "This asks for your login password once, to stop every build and"
	@echo "every launch asking for it again."
	@security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
		-D "$(SIGNING_CN)" $$HOME/Library/Keychains/login.keychain-db || true
	@security set-generic-password-partition-list -S apple-tool:,apple: \
		-s com.atrium-mac.capture.oauth $$HOME/Library/Keychains/login.keychain-db || true
	@echo "done — rebuild and relaunch; it should be quiet now"

# Tests.
#
# NOT `swift test`. XCTest and swift-testing both ship with Xcode, and
# this project builds fine with the Command Line Tools alone, so the
# tests are an ordinary executable instead. See Sources/AtriumSelfTest.
#
# Capture is deliberately absent from both targets: a bare binary cannot
# hold the audio-capture grant, so a "does audio flow" assertion here
# would fail while the real app works. Use `make -C Probes bundle` and
# `open Probes/Probe.app` for that question.
test:
	@swift run AtriumSelfTest

# End to end against a real Atrium PA: mints a token, uploads a spoken
# clip, polls until the transcript is ready. Needs credentials, and
# leaves a real capture behind.
#
#   export ATRIUM_BASE_URL=https://…
#   export ATRIUM_CLIENT_ID=…
#   export ATRIUM_CLIENT_SECRET=…
#   make test-live
#
# POLL is how long to wait for transcription before reporting the upload
# as landed-but-still-running.
POLL ?= 300
test-live:
	@swift run AtriumSelfTest --live --poll-seconds $(POLL)

# The original feasibility probes. Kept because they are the fastest way
# to answer "is it the app or is it the machine?".
probes:
	@$(MAKE) --no-print-directory -C Probes

clean:
	swift package clean
	@rm -rf build
	@$(MAKE) --no-print-directory -C Probes clean
