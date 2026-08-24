# Atrium PA Capture — build, bundle, sign, run.
#
# `swift build` alone is NOT enough to get a working app. A bare binary
# cannot hold the audio-capture TCC grant, so the process tap silently
# delivers buffers of zeroes. The bundle is load-bearing; see README.

APP_NAME    := AtriumMac
BUNDLE_NAME := Atrium PA Capture
BUNDLE      := build/$(BUNDLE_NAME).app
CONFIG      := release

# Universal, so this runs on Intel Macs as well as Apple Silicon.
#
# Intel Macs run macOS well past this app's 14.2 floor, and an arm64-only
# build refuses to launch on them with a message that explains nothing.
# The cost is about 1.8 MB of binary.
#
# Override to build only for this machine, which is faster:
#   make ARCHS=arm64
ARCHS       ?= arm64 x86_64
ARCH_FLAGS  := $(foreach a,$(ARCHS),--arch $(a))

# Asked for rather than assumed. A multi-arch build does NOT populate
# .build/$(CONFIG)/ — that path stays single-arch, so hardcoding it
# bundles an arm64-only binary from a universal build and says nothing.
# Measured: after `swift build --arch arm64 --arch x86_64`,
# `lipo -archs .build/release/AtriumMac` still reported just `arm64`.
# Deferred (`=`, not `:=`) so it is resolved when used, not on every
# `make clean`.
BIN          = $(shell swift build -c $(CONFIG) $(ARCH_FLAGS) --show-bin-path)/$(APP_NAME)

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

# A Developer ID wins when there is one, because it is the only identity
# another Mac will accept. The self-signed certificate is the fallback
# for local work, and ad-hoc is the fallback for a fresh checkout with
# neither.
#
# `-v` matters: it lists only identities with a chain that actually
# builds. A Developer ID certificate whose Apple intermediate is missing
# appears in the unfiltered list and then fails to sign with
# "unable to build chain to self-signed root". Choosing from the
# unfiltered list would pick an identity that cannot sign.
DEVELOPER_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
CODESIGN_IDENTITY ?= $(or $(DEVELOPER_ID),$(shell security find-identity -p codesigning \
	2>/dev/null | grep -q "$(SIGNING_CN)" && echo "$(SIGNING_CN)" || echo -))

# Hardened runtime, but only for a real Developer ID.
#
# Notarization requires it, and it requires the microphone entitlement —
# without which a hardened build records silence and does not say why.
# It is deliberately *not* applied to the self-signed development
# identity: that path works today, and turning on a different runtime
# for it would change the one configuration this app is known to capture
# audio in, for no benefit until there is something to notarize.
#
# The timestamp goes with it. `--timestamp=none` is right for a local
# signature — it needs no network and nothing checks it — and fatal for
# a real one: notarization refuses a signature without a secure
# timestamp, and the refusal names neither the flag nor the file.
TIMESTAMP := --timestamp=none
ifneq (,$(findstring Developer ID,$(CODESIGN_IDENTITY)))
SIGN_FLAGS := --options runtime --entitlements Resources/AtriumMac.entitlements
TIMESTAMP := --timestamp
endif

VERSION := $(shell plutil -extract CFBundleShortVersionString raw Resources/Info.plist)

# What Sparkle compares to decide whether an update is newer.
#
# CFBundleVersion sat at "1" for both 0.1.0 and 0.1.1, which would have
# shipped an updater that never offered anything: the feed would list a
# build the app considered equal to itself. Derived from the marketing
# version so it cannot drift — 0.1.1 becomes 101, 1.2.3 becomes 10203 —
# and written into the bundle rather than the source plist, so there is
# no second number to remember to bump.
BUILD_NUMBER := $(shell echo "$(VERSION)" | awk -F. '{printf "%d", $$1*10000 + $$2*100 + $$3}')

# Sparkle, unpacked by SwiftPM. Both the framework the app embeds and
# the tools that sign a release live here.
SPARKLE_DIR := .build/artifacts/sparkle/Sparkle
SPARKLE_FRAMEWORK := $(SPARKLE_DIR)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
APPCAST_DIR := docs
REPO := brendanbank/atrium-pa-mac
# No spaces in the file name, deliberately.
#
# GitHub rewrites spaces when a release asset is uploaded — "Atrium PA
# Capture 0.2.0.dmg" arrives as "Atrium.PA.Capture.0.2.0.dmg" — so an
# appcast URL built from the local name 404s, and the update silently
# never installs. The volume name inside the image is still the readable
# one, which is what a person actually sees when they open it.
DMG     := build/Atrium-PA-Capture-$(VERSION).dmg
DMG_ROOT := build/dmg
NOTARIZE_ZIP := build/notarize.zip

# Notarization credentials, stored once with:
#
#   xcrun notarytool store-credentials atrium-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific>
#
NOTARY_PROFILE ?= atrium-notary

.PHONY: all build bundle sign run clean probes verify test test-live signing-identity trust-keychain icon install dmg dmg-image notarize appcast

all: bundle

build:
	swift build -c $(CONFIG) $(ARCH_FLAGS)

bundle: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	@cp "$(BIN)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@for a in $(ARCHS); do \
		lipo -archs "$(BUNDLE)/Contents/MacOS/$(APP_NAME)" | grep -qw $$a || { \
			echo "the bundled binary is missing $$a"; \
			echo "   has: $$(lipo -archs "$(BUNDLE)/Contents/MacOS/$(APP_NAME)")"; \
			exit 1; \
		}; \
	done
	@cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	@plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" \
		"$(BUNDLE)/Contents/Info.plist"
	@mkdir -p "$(BUNDLE)/Contents/Frameworks"
	@cp -R "$(SPARKLE_FRAMEWORK)" "$(BUNDLE)/Contents/Frameworks/"
	@install_name_tool -add_rpath @executable_path/../Frameworks \
		"$(BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(BUNDLE)/Contents/PkgInfo"
	@$(MAKE) --no-print-directory sign
	@echo "built $(BUNDLE) [$$(lipo -archs "$(BUNDLE)/Contents/MacOS/$(APP_NAME)")]"

sign:
	@# Inside out. `codesign` seals nested code, so signing the app around
	@# unsigned nested code produces a bundle that fails its own
	@# verification, and Sparkle's XCFramework arrives unsigned from
	@# SwiftPM.
	@#
	@# Every nested Mach-O is named explicitly rather than found by
	@# pattern. The first version of this matched only `*.xpc` and
	@# `*.app`, which silently missed `Versions/B/Autoupdate` — a bare
	@# executable, not a bundle. `codesign --deep` still reported the app
	@# valid, and Apple rejected the notarisation four minutes later with
	@# "The binary is not signed with a valid Developer ID certificate".
	@# A local check that passes while the authoritative one fails is
	@# worse than no check, so the list is the list.
	@if [ -d "$(BUNDLE)/Contents/Frameworks/Sparkle.framework" ]; then \
		F="$(BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" $(TIMESTAMP) $(SIGN_FLAGS) \
			"$$F/Versions/B/XPCServices/Downloader.xpc" \
			"$$F/Versions/B/XPCServices/Installer.xpc" \
			"$$F/Versions/B/Updater.app" \
			"$$F/Versions/B/Autoupdate"; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" $(TIMESTAMP) $(SIGN_FLAGS) "$$F"; \
	fi
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(TIMESTAMP) $(SIGN_FLAGS) "$(BUNDLE)"
	@codesign -dv "$(BUNDLE)" 2>&1 | grep -E 'Identifier|Info.plist' || true
	@# Ask locally what Apple asks. `codesign --deep` calls a bundle
	@# valid while a nested binary carries the wrong identity, so it
	@# cannot answer "will this notarize?" — and finding out from the
	@# notary service costs four minutes per attempt.
	@if echo "$(CODESIGN_IDENTITY)" | grep -q "Developer ID"; then \
		find "$(BUNDLE)" -type f -perm +111 | while read -r f; do \
			file "$$f" | grep -q Mach-O || continue; \
			codesign -dvvv "$$f" 2>&1 | grep -q "Authority=Developer ID Application" \
				|| { echo "not signed with the Developer ID: $$f"; exit 1; }; \
			codesign -dvvv "$$f" 2>&1 | grep -q "^Timestamp=" \
				|| { echo "no secure timestamp: $$f"; exit 1; }; \
		done || exit 1; \
	fi

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
dmg: bundle dmg-image

# Packaging only, with no `bundle` prerequisite on purpose.
#
# `notarize` staples the ticket into the .app and then packages it, and
# `bundle` re-signs — which throws the ticket away. Depending on
# `bundle` here would quietly undo the stapling one line before the
# image was built.
dmg-image:
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
#
# **Two submissions, not one.** Stapling a disk image tickets the image
# and nothing inside it — measured: after `stapler staple` on the dmg,
# the app it contained still reported "does not have a ticket stapled to
# it". Since the whole point of the image is that somebody drags the app
# out of it, the copy they keep is the one that needs the ticket. So the
# app is notarized and stapled first, and the image is built around the
# stapled app and notarized in its own right.
# Refuses rather than submits when the identity is wrong.
#
# It used to print "NOT notarized, you need a Developer ID" from `dmg`
# and then submit the image regardless. Apple takes several minutes to
# answer, and the answer was three errors that were all knowable before
# the upload: not a Developer ID certificate, no secure timestamp, no
# hardened runtime. Those are exactly the three things CODESIGN_IDENTITY
# decides, so check it here instead of asking Cupertino.
notarize: bundle
	@echo "$(CODESIGN_IDENTITY)" | grep -q "Developer ID" || { \
		echo "refusing to submit: signed with '$(CODESIGN_IDENTITY)'"; \
		echo "   Notarization needs a Developer ID Application certificate."; \
		echo "   'make signing-identity' shows what this machine has."; \
		exit 1; \
	}
	@echo "[1/2] notarizing the app — this takes a few minutes"
	@rm -f "$(NOTARIZE_ZIP)"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(NOTARIZE_ZIP)"
	@xcrun notarytool submit "$(NOTARIZE_ZIP)" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	@rm -f "$(NOTARIZE_ZIP)"
	@xcrun stapler staple "$(BUNDLE)"
	@echo "[2/2] notarizing the image"
	@$(MAKE) --no-print-directory dmg-image
	@xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple "$(DMG)"
	@xcrun stapler validate "$(DMG)"
	@spctl --assess --type open --context context:primary-signature -v "$(DMG)" || true
	@echo "notarized and stapled — this image opens on any Mac, offline"
	@$(MAKE) --no-print-directory appcast

# Sign the release into the update feed.
#
# `generate_appcast` signs each image with the EdDSA key in the login
# Keychain — the one that never leaves this Mac, and the reason a
# compromised GitHub account still cannot push a malicious update.
#
# The URL rewrite is the awkward part. GitHub puts the tag in the asset
# path, so every version has a different prefix and `--download-url-prefix`
# can only hold one. Rather than host the images on Pages and grow the
# repository by a disk image per release for ever, the enclosure URLs are
# rewritten afterwards from each item's own version.
appcast:
	@mkdir -p "$(APPCAST_DIR)" build/appcast
	@cp "$(DMG)" build/appcast/ 2>/dev/null || true
	@$(SPARKLE_DIR)/bin/generate_appcast build/appcast \
		--download-url-prefix "https://github.com/$(REPO)/releases/download/PLACEHOLDER/"
	@python3 Tools/fix-appcast.py build/appcast/appcast.xml "$(APPCAST_DIR)/appcast.xml" \
		"https://github.com/$(REPO)/releases/download"
	@echo "wrote $(APPCAST_DIR)/appcast.xml — commit it, then push to publish"

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
	@echo "builds will sign with: $(CODESIGN_IDENTITY)"
	@echo "$(CODESIGN_IDENTITY)" | grep -q "Developer ID" \
		&& echo "   hardened runtime on, timestamped — 'make notarize' will work" \
		|| echo "   local only. 'make notarize' needs a Developer ID Application cert"

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
