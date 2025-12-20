# Crash Handling and Logging Issue

## Problem

spotupnp suddenly crashed with a segmentation fault (SIGSEGV signal 11), but **nothing appeared in the application logs**. The crash was only visible in kernel logs (`dmesg`):

```
[34405.411424] spotupnp-linux-[96908]: segfault at 198 ip 00000000004172fc sp 00007185d57f9cf0 error 4
```

The application log showed normal operation right up until the crash, with no error message or indication of failure.

## Root Cause

The current signal handling in [spotupnp/src/spotupnp.c#L1478-1487](../spotupnp/src/spotupnp.c#L1478-1487) only catches **graceful termination signals**:

```c
signal(SIGINT, sighandler);   // Ctrl+C
signal(SIGTERM, sighandler);  // kill command
signal(SIGQUIT, sighandler);  // Ctrl+\
signal(SIGHUP, sighandler);   // terminal hangup
signal(SIGPIPE, SIG_IGN);     // broken pipe (ignored)
```

**Fatal signals are NOT caught:**
- `SIGSEGV` (Segmentation fault) - Invalid memory access
- `SIGABRT` (Abort) - Explicit abort() call or assertion failure
- `SIGBUS` (Bus error) - Invalid memory alignment
- `SIGFPE` (Floating point exception) - Division by zero, etc.
- `SIGILL` (Illegal instruction) - Invalid CPU instruction

When these signals occur, the process terminates immediately without running any cleanup code, and **no logs are written**.

## Current Behavior

### What Gets Logged
- Normal operations
- Handled exceptions
- Graceful shutdowns (SIGTERM, SIGINT)

### What Does NOT Get Logged
- Segmentation faults (SIGSEGV)
- Assertion failures (SIGABRT)
- Memory alignment errors (SIGBUS)
- Divide by zero (SIGFPE)
- C++ uncaught exceptions in threads
- Stack overflows

## Impact

### For Developers
- **Debugging is difficult** - No indication of what caused the crash
- **No stack trace** - Can't identify the failing code path
- **Silent failures** - Process disappears without warning
- **Must check kernel logs** - Extra step to find crashes

### For Users
- Application appears to "just stop" without explanation
- No error messages to report
- Difficult to troubleshoot issues

## Solutions

### Option 1: Add Fatal Signal Handlers (Minimal)

Add handlers for fatal signals to log before crashing:

```c
static void fatal_signal_handler(int signum) {
    const char *signame = "UNKNOWN";
    switch(signum) {
        case SIGSEGV: signame = "SIGSEGV (Segmentation Fault)"; break;
        case SIGABRT: signame = "SIGABRT (Abort)"; break;
        case SIGBUS: signame = "SIGBUS (Bus Error)"; break;
        case SIGFPE: signame = "SIGFPE (Floating Point Exception)"; break;
        case SIGILL: signame = "SIGILL (Illegal Instruction)"; break;
    }
    
    // Use async-signal-safe functions only (no malloc, no LOG_ERROR)
    const char msg[] = "\n***** FATAL ERROR: Caught signal ";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    write(STDERR_FILENO, signame, strlen(signame));
    write(STDERR_FILENO, " *****\n", 7);
    
    // Re-raise the signal to get default behavior (core dump)
    signal(signum, SIG_DFL);
    raise(signum);
}

// In main():
signal(SIGSEGV, fatal_signal_handler);
signal(SIGABRT, fatal_signal_handler);
signal(SIGBUS, fatal_signal_handler);
signal(SIGFPE, fatal_signal_handler);
signal(SIGILL, fatal_signal_handler);
```

**Pros:**
- Simple to implement
- At least logs that a crash occurred
- Allows core dump for debugging

**Cons:**
- No stack trace
- Limited information about crash location
- Must use async-signal-safe functions only

### Option 2: Use sigaction with Backtrace (Better)

More comprehensive handler with stack trace:

```c
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>

static void fatal_signal_handler_detailed(int signum, siginfo_t *info, void *context) {
    const char *signame = "UNKNOWN";
    switch(signum) {
        case SIGSEGV: signame = "SIGSEGV"; break;
        case SIGABRT: signame = "SIGABRT"; break;
        case SIGBUS: signame = "SIGBUS"; break;
        case SIGFPE: signame = "SIGFPE"; break;
        case SIGILL: signame = "SIGILL"; break;
    }
    
    // Log signal info (async-safe)
    char msg[256];
    int len = snprintf(msg, sizeof(msg), 
        "\n***** FATAL: %s at address %p *****\n", 
        signame, info->si_addr);
    write(STDERR_FILENO, msg, len);
    
    // Get stack trace
    void *array[50];
    int size = backtrace(array, 50);
    
    write(STDERR_FILENO, "Stack trace:\n", 13);
    backtrace_symbols_fd(array, size, STDERR_FILENO);
    write(STDERR_FILENO, "\n", 1);
    
    // Restore default handler and re-raise
    signal(signum, SIG_DFL);
    raise(signum);
}

// In main():
struct sigaction sa;
sa.sa_sigaction = fatal_signal_handler_detailed;
sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
sigemptyset(&sa.sa_mask);

sigaction(SIGSEGV, &sa, NULL);
sigaction(SIGABRT, &sa, NULL);
sigaction(SIGBUS, &sa, NULL);
sigaction(SIGFPE, &sa, NULL);
sigaction(SIGILL, &sa, NULL);
```

**Pros:**
- Provides stack trace
- Shows crash address
- Better debugging information
- Still allows core dump

**Cons:**
- More complex
- Stack trace may not have symbols without debug info
- Still limited by async-signal-safe restrictions

### Option 3: Integrate Crash Reporter Library (Best)

Use established crash reporting libraries:

**Google Breakpad:**
```c
// Initialize Breakpad at startup
#include "client/linux/handler/exception_handler.h"

bool crash_callback(const MinidumpDescriptor& descriptor,
                   void* context, bool succeeded) {
    LOG_ERROR("Crash dump written to: %s", descriptor.path());
    return succeeded;
}

// In main():
MinidumpDescriptor descriptor("/tmp/crash-dumps");
ExceptionHandler eh(descriptor, NULL, crash_callback, NULL, true, -1);
```

**Pros:**
- Full crash dumps with stack traces
- Cross-platform
- Industry standard
- Can upload dumps for analysis
- Handles all crash types including C++ exceptions

**Cons:**
- External dependency
- Larger binary size
- More setup required

### Option 4: Enhanced Logging Setup

Ensure stderr/stdout are properly captured even during crashes:

**Current logging in dev-run/build.sh:**
```bash
nohup "$BINARY_PATH" -x "$CONFIG_PATH" > "$LOG_FILE" 2>&1 &
```

This redirects both stdout and stderr, which is good. However, fatal signals bypass this.

**Add core dump enable:**
```bash
# Enable core dumps for debugging
ulimit -c unlimited
CORE_PATTERN="/tmp/core.%e.%p"
```

## Recommended Implementation

### Phase 1: Immediate (Quick Fix)

Add basic fatal signal logging:

**File**: [spotupnp/src/spotupnp.c](../spotupnp/src/spotupnp.c)

```c
// Add after existing signal handler
static void fatal_signal_handler(int signum) {
    const char *signame = "UNKNOWN";
    switch(signum) {
        case SIGSEGV: signame = "SIGSEGV (Segmentation Fault)"; break;
        case SIGABRT: signame = "SIGABRT (Abort)"; break;
        case SIGBUS: signame = "SIGBUS (Bus Error)"; break;
        case SIGFPE: signame = "SIGFPE (Floating Point Exception)"; break;
        case SIGILL: signame = "SIGILL (Illegal Instruction)"; break;
    }
    
    // Async-signal-safe logging
    const char msg1[] = "\n##### FATAL CRASH: Signal ";
    write(STDERR_FILENO, msg1, sizeof(msg1) - 1);
    write(STDERR_FILENO, signame, strlen(signame));
    write(STDERR_FILENO, " #####\n", 7);
    write(STDERR_FILENO, "Check dmesg for details\n", 24);
    
    // Flush logs
    fsync(STDERR_FILENO);
    
    // Re-raise for default handling (core dump)
    signal(signum, SIG_DFL);
    raise(signum);
}

// In main(), after existing signal handlers:
signal(SIGSEGV, fatal_signal_handler);
signal(SIGABRT, fatal_signal_handler);
#ifdef SIGBUS
signal(SIGBUS, fatal_signal_handler);
#endif
signal(SIGFPE, fatal_signal_handler);
signal(SIGILL, fatal_signal_handler);
```

### Phase 2: Enhanced (Better Diagnostics)

Add stack trace support:

1. Add `-rdynamic` to CMakeLists.txt for better symbols
2. Use `sigaction` with backtrace
3. Add helper script to decode addresses with `addr2line`

### Phase 3: Production (Professional)

Integrate Google Breakpad or similar:
- Automatic crash dumps
- Symbol upload for analysis
- Crash statistics tracking

## Additional Crash Detection

### 1. Enable Core Dumps

In systemd service or startup script:
```bash
ulimit -c unlimited
```

In `/etc/sysctl.conf`:
```
kernel.core_pattern = /tmp/core.%e.%p.%t
```

### 2. Monitor with systemd

If running as systemd service, the service manager already logs crashes:
```bash
journalctl -u spotupnp -n 100
```

### 3. Watchdog/Monitor Process

Add external monitoring that detects when process dies unexpectedly.

## The Specific Crash

From the kernel log:
```
[34405.411424] spotupnp-linux-[96908]: segfault at 198 ip 00000000004172fc
```

- **Address**: `0x198` - Very low address, likely NULL pointer dereference
- **Instruction pointer**: `0x4172fc` - Can use `addr2line` to find source
- **Error code 4**: Read access to unmapped memory

To debug:
```bash
addr2line -e spotupnp-linux-x86_64-static 0x4172fc
```

Or use GDB with core dump:
```bash
gdb spotupnp-linux-x86_64-static core.96908
bt full  # Show full backtrace
```

## Testing Crash Handlers

To test the crash handler:

```c
// Add temporary test code
void test_crash_handler(void) {
    LOG_INFO("Testing SIGSEGV handler...", NULL);
    int *p = NULL;
    *p = 42;  // Intentional segfault
}
```

## Related Files

- [spotupnp/src/spotupnp.c](../spotupnp/src/spotupnp.c) - Main signal handling
- [spotupnp/dev-run/build.sh](../spotupnp/dev-run/build.sh) - Logging setup
- [spotupnp/CMakeLists.txt](../spotupnp/CMakeLists.txt) - Build configuration

## References

- Signal handling: `man 7 signal`
- sigaction: `man 2 sigaction`
- backtrace: `man 3 backtrace`
- Google Breakpad: https://chromium.googlesource.com/breakpad/breakpad/
- Async-signal-safe functions: `man 7 signal-safety`
