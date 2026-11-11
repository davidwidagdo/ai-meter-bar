#!/usr/bin/env bash
# Compiles the pure-logic units + tests into a standalone executable and runs it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> macos-app/
OUT="$(mktemp -d)/tests"
swiftc -o "$OUT" \
  Sources/ByteFormatter.swift \
  Sources/SpeedMath.swift \
  Sources/UsageStore.swift \
  Sources/CPUMath.swift \
  Sources/MemoryMath.swift \
  Sources/SystemFormat.swift \
  Sources/LoginForm.swift \
  Sources/AppMode.swift \
  Sources/LoginOutcome.swift \
  Sources/PortalDiagnostics.swift \
  Tests/PortalDiagnosticsTests.swift \
  Sources/LoginThrottle.swift \
  Tests/LoginOutcomeTests.swift \
  Sources/UsageModels.swift \
  Sources/LocalUsageReaders.swift \
  Sources/ClaudeProfiles.swift \
  Sources/ClaudeLauncher.swift \
  Sources/DemoData.swift \
  Tests/AIUsageTests.swift \
  Tests/ClaudeProfilesTests.swift \
  Sources/MeterClock.swift \
  Tests/MeterClockTests.swift \
  Sources/VPN.swift \
  Sources/PortalSecret.swift \
  Tests/AuditTests.swift \
  Tests/VPNTests.swift \
  Tests/TestSupport.swift \
  Tests/ByteFormatterTests.swift \
  Tests/SpeedMathTests.swift \
  Tests/UsageStoreTests.swift \
  Tests/CPUMathTests.swift \
  Tests/MemoryMathTests.swift \
  Tests/SystemFormatTests.swift \
  Tests/LoginFormTests.swift \
  Tests/main.swift
"$OUT"
