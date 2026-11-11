/* Zig defines _FORTIFY_SOURCE in optimized builds; glibc's fortified
   wrappers use __attribute__((error)) which translate-c cannot handle.
   We don't need them for a translated header. */
#undef _FORTIFY_SOURCE
#include <stdlib.h>
#include <stdio.h>
#if !defined(_WIN32)
/* POSIX: Linux and macOS (fifo channel, shell audio, roaming groups). */
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/un.h>
#endif
#if defined(__linux__)
/* Xlib, XFixes and XRandR for the x11 backend. Windows (win32.zig) and
   macOS (appkit.zig) declare what they call themselves. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/shape.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/Xrandr.h>
#endif
