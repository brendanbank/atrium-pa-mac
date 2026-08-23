# Standalone feasibility probes. Each is a single self-contained file.
#
# NOTE: tap-capture as a bare CLI will report SILENCE. That is not a bug
# — it is the finding. Run `make bundle` here to wrap it in a real .app
# and watch the same binary start capturing real audio.

SWIFTC := swiftc -O
PROBES := mic-detect tap-probe tap-capture dump-procs win-titles

.PHONY: all clean bundle

all: $(PROBES)

mic-detect: mic-detect.swift
	$(SWIFTC) $< -o $@ -framework CoreAudio

tap-probe: tap-probe.swift
	$(SWIFTC) $< -o $@ -framework CoreAudio

tap-capture: tap-capture.swift
	$(SWIFTC) $< -o $@ -framework CoreAudio

dump-procs: dump-procs.swift
	$(SWIFTC) $< -o $@ -framework CoreAudio

win-titles: win-titles.swift
	$(SWIFTC) $< -o $@

# Wrap tap-capture in a minimal bundle to demonstrate the A/B: identical
# binary, silence as a CLI, real audio as a bundled app.
bundle: tap-capture
	@rm -rf Probe.app
	@mkdir -p Probe.app/Contents/MacOS
	@cp tap-capture Probe.app/Contents/MacOS/Probe
	@# PlistBuddy creates the file itself ("File Doesn't Exist, Will
	@# Create" on stderr). Seeding it with a bare XML declaration first
	@# left a half-written document that PlistBuddy then refused to parse.
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Probe" \
		-c "Add :CFBundleIdentifier string com.atrium-mac.audioprobe" \
		-c "Add :CFBundleName string Atrium PA Audio Probe" \
		-c "Add :CFBundlePackageType string APPL" \
		-c "Add :LSUIElement bool true" \
		-c "Add :LSMinimumSystemVersion string 14.2" \
		-c "Add :NSAudioCaptureUsageDescription string Feasibility probe." \
		-c "Add :NSMicrophoneUsageDescription string Feasibility probe." \
		Probe.app/Contents/Info.plist >/dev/null
	@codesign --force --sign - Probe.app
	@echo "run with:  open Probe.app  &&  cat /tmp/atrium-probe.log"

clean:
	@rm -rf $(PROBES) Probe.app *.dSYM
