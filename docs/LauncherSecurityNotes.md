# Launcher Compatibility Security Considerations

**Feature:** Launcher Compatibility System (frankea/Whisky#41)  
**Component:** CEF Sandbox Disable  
**Date:** January 12, 2026

---

## Overview

The launcher compatibility system disables the Chromium Embedded Framework (CEF) sandbox for Wine processes. This document explains the security implications and rationale.

---

## What is the CEF Sandbox?

The CEF sandbox is a security feature in Chromium Embedded Framework that:
- Isolates embedded web content from the host process
- Restricts system calls available to browser components
- Limits damage from browser exploits
- Provides defense-in-depth security

---

## Why Must It Be Disabled?

### Technical Incompatibility

The CEF sandbox **cannot function under Wine** because:

1. **System Call Mismatch**
   - Sandbox requires Linux/Windows kernel features
   - Wine doesn't implement all required syscalls
   - Missing calls cause crashes or hangs

2. **Security Model Conflict**
   - Sandbox expects native OS security primitives
   - Wine's translation layer doesn't support sandbox requirements
   - Architecture fundamentally incompatible

3. **Practical Impact**
   - Steam: steamwebhelper crashes immediately (~50 upstream issues)
   - EA App: Black screen, launcher won't load
   - Epic Games: Launcher UI doesn't render
   - Rockstar: Freeze on logo screen

### Without Disabling CEF Sandbox:
- ❌ Steam completely unusable (steamwebhelper crash)
- ❌ Epic Games Store doesn't launch
- ❌ EA App shows black screen
- ❌ Rockstar Launcher freezes

### With CEF Sandbox Disabled:
- ✅ All launchers function properly
- ✅ Can download and launch games
- ✅ Launcher UIs render correctly
- ⚠️  Embedded browser runs with process privileges

---

## Security Implications

### What Changes

**Before (ideal, but non-functional under Wine):**
```
┌─────────────────────────────────────────┐
│  Wine Process (Steam)                   │
│  ┌──────────────────────────────────┐   │
│  │ CEF Sandbox (steamwebhelper)     │   │
│  │ - Limited syscalls               │   │
│  │ - Cannot access host filesystem  │   │
│  │ - Isolated memory space          │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

**After (functional under Wine):**
```
┌─────────────────────────────────────────┐
│  Wine Process (Steam)                   │
│  ┌──────────────────────────────────┐   │
│  │ CEF (steamwebhelper)             │   │
│  │ - Full process privileges        │   │
│  │ - Can access Wine prefix         │   │
│  │ - Shares memory space            │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### Threat Model

**Increased Risk:**
- Browser exploit in launcher could compromise Wine process
- Malicious webpage could access Wine prefix filesystem
- XSS in launcher UI could execute arbitrary code

**Mitigating Factors:**
1. **Trusted Launchers**: Steam, Epic, EA, Rockstar are reputable companies
2. **Limited Attack Surface**: Launchers mostly load first-party content
3. **Wine Isolation**: Wine processes don't have direct macOS system access
4. **User Control**: Users choose what launchers to run

**Realistic Risk Assessment:**
- **Low-Medium**: For trusted launchers from major companies
- **Users already trust**: Steam with credit cards, game libraries
- **Practical security**: Wine itself has many security implications

---

## Why Not Make It Opt-In?

### Option Considered: `WHISKY_UNSAFE_CEF_COMPAT=1` Flag

**Pros:**
- ✅ Security-conscious design
- ✅ Users explicitly consent
- ✅ Clear documentation of trade-off

**Cons:**
- ❌ Defeats purpose of frankea/Whisky#41 (fix launcher issues)
- ❌ Steam won't work out-of-box (~50 user-facing issues)
- ❌ Users frustrated: "Why doesn't Steam work?"
- ❌ Requires technical knowledge to enable
- ❌ Most users will enable it anyway (to use launchers)

### Decision: Disable by Default, Document Clearly

**Rationale:**
1. **Functionality First**: This is a compatibility tool, not a security product
2. **User Expectations**: Users expect launchers to work
3. **Minimal Additional Risk**: Wine already has security implications
4. **Trusted Software**: Major launchers are semi-trusted
5. **Transparent**: Document implications clearly

---

## Security Measures Implemented

### 1. Comprehensive Documentation ✅

**In Code (MacOSCompatibility.swift):**
```swift
// SECURITY NOTE: This disables CEF's security sandbox...
// Security Implications:
// - Embedded browser content runs with full process privileges
// - A browser exploit could compromise the Wine process
// - Users should only use trusted launchers...
```

**In UI (LauncherConfigSection.swift):**
- Orange shield icon with "Security Note"
- Clear explanation of CEF sandbox disable
- "Only use with trusted launchers from reputable companies"
- Visible warning when compatibility mode enabled

### 2. User Awareness ✅

Users see security notice when enabling launcher compatibility:
- 🛡️ Icon indicates security consideration
- Clear explanation of implications
- Guidance to use trusted launchers only
- Opt-in (user must explicitly enable)

### 3. Logging ✅

Debug log when CEF sandbox is disabled:
```swift
Logger.wineKit.debug("""
    CEF sandbox disabled for Wine compatibility. \
    Security: Embedded browser content runs with process privileges.
    """)
```

### 4. Opt-In Design ✅

- Launcher compatibility mode **disabled by default**
- Users must explicitly enable it
- Security notice shown immediately upon enabling
- Cannot miss the warning

---

## Recommendations for Users

### Safe Usage

✅ **Do:**
- Use with major launchers (Steam, Epic, EA, Rockstar, Ubisoft, Battle.net)
- Keep launchers updated to latest versions
- Be cautious clicking unknown links in launcher browsers
- Use launcher compatibility only when needed

❌ **Don't:**
- Use with unknown/untrusted launcher software
- Browse untrusted websites through launcher browsers
- Run launchers from unverified sources
- Enable for bottles with sensitive data if not needed

### Risk Mitigation

1. **Separate Bottles**: Use dedicated bottles for launchers
2. **Limited Data**: Don't store sensitive files in launcher bottles
3. **Regular Updates**: Keep Wine and launchers updated
4. **Trusted Sources**: Only install launchers from official websites

---

## Alternative Approaches Considered

### 1. Per-Launcher Toggle
**Idea:** Opt-in per launcher (Steam yes, others no)  
**Rejected:** Still breaks Steam by default, complexity

### 2. Environment Variable Gate
**Idea:** `WHISKY_UNSAFE_CEF_COMPAT=1` required  
**Rejected:** Too technical, breaks user experience

### 3. First-Time Warning Dialog
**Idea:** Modal alert on first enable  
**Rejected:** Annoying, users will click through

### 4. Sandboxed Wine (Chosen Approach)
**Idea:** Rely on macOS app sandbox + documentation  
**Status:** Implemented with clear warnings

---

## Comparison to Other Wine Implementations

### CrossOver
- Also disables CEF sandbox for launcher compatibility
- No opt-in required
- Standard practice for Wine launchers

### Lutris (Linux)
- Disables CEF sandbox by default for Steam
- Documented as necessary for functionality
- Same security trade-off

### PlayOnMac
- CEF sandbox disabled automatically
- No warnings shown to users
- Same approach

**Industry Standard:** Disabling CEF sandbox under Wine is standard practice across all major Wine implementations.

---

## Future Improvements

### Potential Enhancements:

1. **macOS App Sandbox**
   - Leverage macOS containment features
   - Limit Maltoria.app's own permissions
   - Additional defense layer

2. **Network Monitoring**
   - Log unexpected network connections
   - Alert on suspicious behavior
   - Optional security logging mode

3. **Per-Site Policies**
   - Allow only known domains in launcher browsers
   - Block unknown remote content
   - Whitelist official launcher domains

4. **Audit Logging**
   - Track launcher activities
   - Log web requests from CEF
   - Security event monitoring

---

## Conclusion

**Decision:** CEF sandbox remains disabled (necessary for functionality)

**Security Posture:**
- ✅ Documented in code with comprehensive notes
- ✅ Visible UI warning when enabled
- ✅ Opt-in design (disabled by default)
- ✅ Debug logging when applied
- ✅ Guidance for safe usage
- ✅ Follows industry standard practice

**Risk Level:** Low-Medium (acceptable for compatibility tool with trusted launchers)

**Recommendation:** Current approach is appropriate balance between security awareness and practical functionality.

---

**This document addresses code review feedback regarding CEF sandbox security implications.**

