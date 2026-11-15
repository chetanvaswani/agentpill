// pill-hook: forwards a Claude Code hook payload (stdin) to the AgentPill app.
// Prints nothing and always exits 0, so it can never add tokens or block the agent.
//
//   pill-hook hook            forward the JSON on stdin
//   pill-hook say "message"   show a free-form message

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static void write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n <= 0) _exit(0);
        buf += n;
        len -= (size_t)n;
    }
}

static void write_json_string(int fd, const char *s) {
    char out[8];
    write_all(fd, "\"", 1);
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') {
            out[0] = '\\';
            out[1] = (char)c;
            write_all(fd, out, 2);
        } else if (c < 0x20) {
            write_all(fd, " ", 1);
        } else {
            write_all(fd, s, 1);
        }
    }
    write_all(fd, "\"", 1);
}

static pid_t parent_of(pid_t pid) {
    struct kinfo_proc info;
    size_t len = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &info, &len, NULL, 0) != 0 || len == 0) return 0;
    return info.kp_eproc.e_ppid;
}

// Header lines ahead of the JSON, so the app can bring the right app to the front on a click:
//   #pids <parent> <grandparent> ...   (the app picks the first one that is a regular app)
//   #bundle <id>                       (__CFBundleIdentifier, set by the app that started the shell)
//   #host <local_...>                  (Claude desktop's id for the session, when it runs there)
static void write_header(int fd) {
    char line[512];
    int len = snprintf(line, sizeof(line), "#pids");
    pid_t pid = getppid();
    for (int depth = 0; pid > 1 && depth < 24 && len < (int)sizeof(line) - 16; depth++) {
        len += snprintf(line + len, sizeof(line) - (size_t)len, " %d", (int)pid);
        pid = parent_of(pid);
    }
    line[len++] = '\n';
    write_all(fd, line, (size_t)len);
    // Claude desktop's own id for this session (local_...): lets a click open exactly this session.
    const char *host = getenv("CLAUDE_CODE_HOST_SESSION_ID");
    if (host && *host && strlen(host) < 100 && strspn(host,
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") == strlen(host)) {
        write_all(fd, "#host ", 6);
        write_all(fd, host, strlen(host));
        write_all(fd, "\n", 1);
    }
    const char *bundle = getenv("__CFBundleIdentifier");
    if (bundle && *bundle && strlen(bundle) < 200 && !strchr(bundle, '\n')) {
        write_all(fd, "#bundle ", 8);
        write_all(fd, bundle, strlen(bundle));
        write_all(fd, "\n", 1);
    }
}

int main(int argc, char **argv) {
    const char *home = getenv("HOME");
    if (!home) return 0;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (snprintf(addr.sun_path, sizeof(addr.sun_path), "%s/.agentpill/pill.sock", home)
        >= (int)sizeof(addr.sun_path)) return 0;

    signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct timeval tv = {1, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) return 0; // app not running
    write_header(fd);

    if (argc >= 3 && strcmp(argv[1], "say") == 0) {
        char cwd[1024];
        if (!getcwd(cwd, sizeof(cwd))) cwd[0] = 0;
        const char *head = "{\"hook_event_name\":\"Say\",\"session_id\":\"say\",\"cwd\":";
        write_all(fd, head, strlen(head));
        write_json_string(fd, cwd);
        write_all(fd, ",\"message\":", 11);
        write_json_string(fd, argv[2]);
        write_all(fd, "}", 1);
    } else {
        // Forward only the head of the payload: everything the pill shows lives in the
        // first few KB. The rest (file contents, tool output) is read and dropped.
        static char buf[65536];
        size_t budget = sizeof(buf);
        ssize_t n;
        while ((n = read(0, buf, sizeof(buf))) > 0) {
            size_t take = (size_t)n < budget ? (size_t)n : budget;
            if (take == 0) continue;
            write_all(fd, buf, take);
            budget -= take;
            if (budget == 0) shutdown(fd, SHUT_WR);
        }
    }
    close(fd);
    return 0;
}
