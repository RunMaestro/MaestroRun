/*
 * maestro-run - run approved scripts under one stable macOS privacy identity.
 *
 * macOS keys its privacy grants (Full Disk Access and the rest of TCC) on the
 * code identity of the responsible process. An ad-hoc signed interpreter has
 * no stable identity, so its grant is pinned to a code hash and dies on every
 * upgrade. This launcher carries a Developer ID identity, makes itself the
 * responsible process, checks the script against an allowlist, and then
 * replaces itself with the script. Whatever the script runs inherits the grant.
 *
 * The command line, the exit codes and the allowlist format are a contract
 * with the tools that drive this binary. See docs/CONTRACT.md before changing
 * any of them.
 */

#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef MAESTRO_RUN_VERSION
#define MAESTRO_RUN_VERSION "0.0.0-dev"
#endif

#define EXIT_NOT_FOUND 1
#define EXIT_NO_ACCESS 3
#define EXIT_USAGE 64
#define EXIT_DENIED 126
#define EXIT_EXEC_FAILED 127

/* Overridden only by tests/run.sh, which cannot write under /Library. */
#ifndef SYSTEM_DIR
#define SYSTEM_DIR "/Library/Application Support/MaestroRun"
#endif
#define USER_DIR_SUFFIX "/Library/Application Support/MaestroRun"
#define LOG_DIR_SUFFIX "/Library/Logs/MaestroRun"
#define ALLOWLIST_NAME "allowlist"
#define ALLOWLIST_HEADER "# maestro-run allowlist v1: sha256<TAB>interpreter<TAB>script"
#define DIRECT_EXEC "-"
#define CONFIG_ENV "MAESTRO_RUN_CONFIG_DIR"
#define STAGE_ENV "__MAESTRO_RUN_STAGE"
#define TCC_PROBE_SUFFIX "/Library/Application Support/com.apple.TCC/TCC.db"
#define BUNDLE_BINARY_SUFFIX "/Contents/MacOS/maestro-run"
#define HASH_HEX_LEN (CC_SHA256_DIGEST_LENGTH * 2)

extern char **environ;

typedef struct {
	char hash[HASH_HEX_LEN + 1];
	char *interpreter;
	char *script;
} entry_t;

typedef struct {
	entry_t *items;
	size_t count;
} allowlist_t;

typedef struct {
	char dir[PATH_MAX];
	char path[PATH_MAX];
	char log_dir[PATH_MAX];
	int is_system;
} location_t;

/* Private SPI, resolved at run time so a release that drops either symbol
 * degrades to "no disclaim" instead of failing to launch. */
typedef int (*setdisclaim_fn)(posix_spawnattr_t *, int);
typedef pid_t (*responsible_fn)(pid_t);

static void die(int code, const char *fmt, ...) __attribute__((noreturn, format(printf, 2, 3)));

static void die(int code, const char *fmt, ...)
{
	va_list ap;

	fputs("maestro-run: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(code);
}

static void path_join(char *out, size_t size, const char *a, const char *b)
{
	int n = snprintf(out, size, "%s%s", a, b);

	if (n < 0 || (size_t)n >= size)
		die(EXIT_DENIED, "path is too long: %s%s", a, b);
}

static char *xstrdup(const char *s)
{
	char *copy = strdup(s);

	if (!copy)
		die(EXIT_DENIED, "out of memory");
	return copy;
}

/* The password database, not $HOME: the environment belongs to the caller. */
static const char *home_dir(void)
{
	struct passwd *pw = getpwuid(getuid());

	if (!pw || !pw->pw_dir || pw->pw_dir[0] != '/')
		die(EXIT_DENIED, "cannot resolve the home directory of uid %d", (int)getuid());
	return pw->pw_dir;
}

/*
 * A system allowlist, when present, is the only one read. It is root-owned,
 * so a process running as the user cannot add itself to it.
 */
static void resolve_location(location_t *loc, int force_system)
{
	struct stat st;
	const char *home = home_dir();
	const char *override = getenv(CONFIG_ENV);

	path_join(loc->path, sizeof loc->path, SYSTEM_DIR, "/" ALLOWLIST_NAME);
	path_join(loc->log_dir, sizeof loc->log_dir, home, LOG_DIR_SUFFIX);
	loc->is_system = force_system || lstat(loc->path, &st) == 0;
	/* Only "it is not there" selects the user list. A system list that
	 * cannot be examined is not an absent one. */
	if (!loc->is_system && errno != ENOENT)
		die(EXIT_DENIED, "cannot check for a system allowlist at %s: %s", loc->path, strerror(errno));
	if (loc->is_system) {
		path_join(loc->dir, sizeof loc->dir, SYSTEM_DIR, "");
		return;
	}
	if (override && override[0] == '/') {
		path_join(loc->dir, sizeof loc->dir, override, "");
		path_join(loc->log_dir, sizeof loc->log_dir, override, "/log");
	} else {
		path_join(loc->dir, sizeof loc->dir, home, USER_DIR_SUFFIX);
	}
	path_join(loc->path, sizeof loc->path, loc->dir, "/" ALLOWLIST_NAME);
}

static int hash_file(const char *path, char out[HASH_HEX_LEN + 1])
{
	static const char hex[] = "0123456789abcdef";
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	unsigned char buf[65536];
	struct stat st;
	CC_SHA256_CTX ctx;
	ssize_t n;
	int fd = open(path, O_RDONLY | O_CLOEXEC);

	if (fd < 0)
		return -1;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
		close(fd);
		errno = EFTYPE;
		return -1;
	}
	CC_SHA256_Init(&ctx);
	for (;;) {
		n = read(fd, buf, sizeof buf);
		if (n > 0) {
			CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
		} else if (n == 0) {
			break;
		} else if (errno != EINTR) {
			int saved = errno;

			close(fd);
			errno = saved;
			return -1;
		}
	}
	close(fd);
	CC_SHA256_Final(digest, &ctx);
	for (size_t i = 0; i < sizeof digest; i++) {
		out[i * 2] = hex[digest[i] >> 4];
		out[i * 2 + 1] = hex[digest[i] & 0x0f];
	}
	out[HASH_HEX_LEN] = '\0';
	return 0;
}

static int is_hash(const char *s)
{
	if (strlen(s) != HASH_HEX_LEN)
		return 0;
	for (const char *p = s; *p; p++) {
		if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f')))
			return 0;
	}
	return 1;
}

static int is_interpreter(const char *s)
{
	return strcmp(s, DIRECT_EXEC) == 0 || s[0] == '/';
}

static void append_entry(allowlist_t *list, const char *hash, const char *interpreter, const char *script)
{
	entry_t *grown = realloc(list->items, (list->count + 1) * sizeof *grown);

	if (!grown)
		die(EXIT_DENIED, "out of memory");
	list->items = grown;
	memcpy(grown[list->count].hash, hash, HASH_HEX_LEN + 1);
	grown[list->count].interpreter = xstrdup(interpreter);
	grown[list->count].script = xstrdup(script);
	list->count++;
}

static entry_t *find_entry(const allowlist_t *list, const char *script)
{
	for (size_t i = 0; i < list->count; i++) {
		if (strcmp(list->items[i].script, script) == 0)
			return &list->items[i];
	}
	return NULL;
}

/*
 * Fails closed. A list this process cannot trust (wrong owner, writable by
 * someone else, a line that does not parse) approves nothing.
 */
static void load_allowlist(const location_t *loc, allowlist_t *list)
{
	struct stat st;
	uid_t owner = loc->is_system ? 0 : geteuid();
	char *line = NULL;
	size_t cap = 0;
	ssize_t len;
	FILE *f;
	int fd;

	list->items = NULL;
	list->count = 0;
	fd = open(loc->path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) {
		if (errno == ENOENT)
			return;
		die(EXIT_DENIED, "cannot open allowlist %s: %s", loc->path, strerror(errno));
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))
		die(EXIT_DENIED, "allowlist %s is not a regular file", loc->path);
	if (st.st_uid != owner)
		die(EXIT_DENIED, "allowlist %s has the wrong owner", loc->path);
	if (st.st_mode & (S_IWGRP | S_IWOTH))
		die(EXIT_DENIED, "allowlist %s is writable by group or other", loc->path);
	if (loc->is_system) {
		if (stat(loc->dir, &st) != 0 || st.st_uid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH)))
			die(EXIT_DENIED, "%s must be owned by root and writable only by root", loc->dir);
	}
	f = fdopen(fd, "r");
	if (!f)
		die(EXIT_DENIED, "cannot read allowlist %s: %s", loc->path, strerror(errno));
	while ((len = getline(&line, &cap, f)) > 0) {
		char *interpreter, *script;

		if (line[len - 1] == '\n')
			line[len - 1] = '\0';
		if (line[0] == '\0' || line[0] == '#')
			continue;
		interpreter = strchr(line, '\t');
		script = interpreter ? strchr(interpreter + 1, '\t') : NULL;
		if (!script)
			die(EXIT_DENIED, "allowlist %s has a malformed line", loc->path);
		*interpreter++ = '\0';
		*script++ = '\0';
		if (!is_hash(line) || !is_interpreter(interpreter) || script[0] != '/')
			die(EXIT_DENIED, "allowlist %s has a malformed line", loc->path);
		append_entry(list, line, interpreter, script);
	}
	/* A list that was only partly read is not the list. */
	if (ferror(f))
		die(EXIT_DENIED, "cannot read allowlist %s", loc->path);
	free(line);
	fclose(f);
}

static void save_allowlist(const location_t *loc, const allowlist_t *list)
{
	char tmp[PATH_MAX];
	mode_t dir_mode = loc->is_system ? 0755 : 0700;
	mode_t file_mode = loc->is_system ? 0644 : 0600;
	mode_t mask;
	FILE *f;
	int fd, n, made, saved;

	/* The umask must not decide who can reach a system allowlist. Under
	 * umask 077 the directory would hide the list from every user. */
	mask = umask(0);
	made = mkdir(loc->dir, dir_mode);
	saved = errno;
	umask(mask);
	if (made != 0 && saved != EEXIST)
		die(EXIT_DENIED, "cannot create %s: %s", loc->dir, strerror(saved));
	n = snprintf(tmp, sizeof tmp, "%s.tmp.%d", loc->path, (int)getpid());
	if (n < 0 || (size_t)n >= sizeof tmp)
		die(EXIT_DENIED, "path is too long: %s", loc->path);
	fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, file_mode);
	if (fd < 0)
		die(EXIT_DENIED, "cannot write %s: %s", tmp, strerror(errno));
	f = fdopen(fd, "w");
	if (!f)
		die(EXIT_DENIED, "cannot write %s: %s", tmp, strerror(errno));
	fprintf(f, "%s\n", ALLOWLIST_HEADER);
	for (size_t i = 0; i < list->count; i++)
		fprintf(f, "%s\t%s\t%s\n", list->items[i].hash, list->items[i].interpreter, list->items[i].script);
	/* The umask must not decide who can read a system allowlist. */
	if (fflush(f) != 0 || fchmod(fd, file_mode) != 0 || fsync(fd) != 0 || fclose(f) != 0 ||
	    rename(tmp, loc->path) != 0) {
		saved = errno;
		unlink(tmp);
		die(EXIT_DENIED, "cannot write %s: %s", loc->path, strerror(saved));
	}
}

/* Best effort: a full disk must not stop an approved job from running. */
static void log_event(const location_t *loc, const char *verdict, const char *hash, const char *interpreter,
		      const char *script)
{
	char path[PATH_MAX], stamp[32];
	time_t now = time(NULL);
	struct tm tm;
	int fd, n;

	(void)mkdir(loc->log_dir, 0700);
	n = snprintf(path, sizeof path, "%s/maestro-run.log", loc->log_dir);
	if (n < 0 || (size_t)n >= sizeof path)
		return;
	fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd < 0)
		return;
	gmtime_r(&now, &tm);
	strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", &tm);
	dprintf(fd, "%s\tpid=%d\tppid=%d\tuid=%d\t%s\t%s\t%s\t%s\n", stamp, (int)getpid(), (int)getppid(),
		(int)getuid(), verdict, hash, interpreter, script);
	close(fd);
}

/* The pid macOS holds responsible for this process, or 0 when unknown. */
static pid_t responsible_pid(void)
{
	responsible_fn fn = (responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
	pid_t pid = fn ? fn(getpid()) : 0;

	return pid > 0 ? pid : 0;
}

/*
 * TCC judges the responsible process, and a child normally inherits its
 * parent's. Started from a terminal or from another app, this binary would be
 * judged as that app. Re-executing in place with the disclaim attribute makes
 * it responsible for itself, so its own grant applies wherever it is started.
 * launchd already starts it that way, and then nothing is done.
 */
static void become_responsible(char **argv)
{
	char self[PATH_MAX], resolved[PATH_MAX];
	uint32_t size = sizeof self;
	posix_spawnattr_t attr;
	setdisclaim_fn disclaim;

	if (getenv(STAGE_ENV)) {
		unsetenv(STAGE_ENV);
		return;
	}
	if (responsible_pid() == getpid())
		return;
	disclaim = (setdisclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
	if (!disclaim || _NSGetExecutablePath(self, &size) != 0 || !realpath(self, resolved))
		return;
	if (posix_spawnattr_init(&attr) != 0)
		return;
	if (posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC) == 0 && disclaim(&attr, 1) == 0) {
		setenv(STAGE_ENV, "1", 1);
		/* Replaces this process. It returns only when the spawn failed. */
		posix_spawn(NULL, resolved, NULL, &attr, argv, environ);
		unsetenv(STAGE_ENV);
	}
	posix_spawnattr_destroy(&attr);
}

/* DYLD_* would let the caller load code into the interpreter itself. */
static void scrub_environment(void)
{
	size_t count = 0, kept = 0;
	char **names;

	while (environ[count])
		count++;
	names = calloc(count + 1, sizeof *names);
	if (!names)
		die(EXIT_DENIED, "out of memory");
	for (size_t i = 0; i < count; i++) {
		const char *eq = strchr(environ[i], '=');

		if (eq && strncmp(environ[i], "DYLD_", 5) == 0) {
			names[kept] = strndup(environ[i], (size_t)(eq - environ[i]));
			/* A name that cannot be copied must not survive the scrub. */
			if (!names[kept++])
				die(EXIT_DENIED, "out of memory");
		}
	}
	for (size_t i = 0; i < kept; i++) {
		unsetenv(names[i]);
		free(names[i]);
	}
	free(names);
}

static void resolve_script(const char *arg, char out[PATH_MAX])
{
	if (!realpath(arg, out))
		die(EXIT_DENIED, "cannot resolve %s: %s", arg, strerror(errno));
	if (strchr(out, '\t') || strchr(out, '\n'))
		die(EXIT_DENIED, "paths that contain a tab or a newline are not supported: %s", out);
}

static int cmd_run(int argc, char **argv)
{
	char script[PATH_MAX], actual[HASH_HEX_LEN + 1];
	location_t loc;
	allowlist_t list;
	const entry_t *entry;
	char **child;
	int direct, at = 0;

	if (argc < 1)
		die(EXIT_USAGE, "run needs a script. Try: maestro-run --help");
	resolve_script(argv[0], script);
	resolve_location(&loc, 0);
	load_allowlist(&loc, &list);
	entry = find_entry(&list, script);
	if (!entry) {
		log_event(&loc, "DENY-not-approved", "-", "-", script);
		die(EXIT_DENIED, "%s is not approved. Review it, then run: maestro-run approve '%s'", script, script);
	}
	if (hash_file(script, actual) != 0) {
		log_event(&loc, "DENY-unreadable", entry->hash, entry->interpreter, script);
		die(EXIT_DENIED, "cannot read %s: %s", script, strerror(errno));
	}
	if (strcmp(actual, entry->hash) != 0) {
		log_event(&loc, "DENY-changed", actual, entry->interpreter, script);
		die(EXIT_DENIED, "%s changed after it was approved. Review it, then run: maestro-run approve '%s'",
		    script, script);
	}
	direct = strcmp(entry->interpreter, DIRECT_EXEC) == 0;
	child = calloc((size_t)argc + 2, sizeof *child);
	if (!child)
		die(EXIT_DENIED, "out of memory");
	if (!direct)
		child[at++] = entry->interpreter;
	child[at++] = script;
	for (int i = 1; i < argc; i++)
		child[at++] = argv[i];
	scrub_environment();
	log_event(&loc, "ALLOW", entry->hash, entry->interpreter, script);
	execv(child[0], child);
	die(EXIT_EXEC_FAILED, "cannot execute %s: %s", child[0], strerror(errno));
}

static int cmd_approve(int argc, char **argv)
{
	char script[PATH_MAX], hash[HASH_HEX_LEN + 1];
	const char *interpreter = NULL, *target = NULL;
	location_t loc;
	allowlist_t list;
	entry_t *entry;
	struct stat st;
	int system = 0;

	for (int i = 0; i < argc; i++) {
		if (strcmp(argv[i], "--system") == 0) {
			system = 1;
		} else if (strcmp(argv[i], "--interpreter") == 0) {
			if (++i >= argc)
				die(EXIT_USAGE, "--interpreter needs a path");
			interpreter = argv[i];
		} else if (!target) {
			target = argv[i];
		} else {
			die(EXIT_USAGE, "approve takes one script");
		}
	}
	if (!target)
		die(EXIT_USAGE, "approve needs a script. Try: maestro-run --help");
	resolve_script(target, script);
	if (interpreter && strcmp(interpreter, DIRECT_EXEC) != 0) {
		if (interpreter[0] != '/' || strchr(interpreter, '\t') || strchr(interpreter, '\n'))
			die(EXIT_USAGE, "the interpreter must be an absolute path: %s", interpreter);
		if (stat(interpreter, &st) != 0 || !S_ISREG(st.st_mode) || access(interpreter, X_OK) != 0)
			die(EXIT_USAGE, "the interpreter is not an executable file: %s", interpreter);
	}
	resolve_location(&loc, system);
	if (loc.is_system && geteuid() != 0)
		die(EXIT_DENIED, "the system allowlist decides what runs here. Use: sudo maestro-run approve --system '%s'",
		    script);
	if (hash_file(script, hash) != 0)
		die(EXIT_DENIED, "cannot read %s: %s", script, strerror(errno));
	load_allowlist(&loc, &list);
	entry = find_entry(&list, script);
	if (entry) {
		/* A re-approval after an edit keeps the interpreter it already had. */
		memcpy(entry->hash, hash, sizeof entry->hash);
		if (interpreter)
			entry->interpreter = xstrdup(interpreter);
	} else {
		append_entry(&list, hash, interpreter ? interpreter : DIRECT_EXEC, script);
		entry = &list.items[list.count - 1];
	}
	save_allowlist(&loc, &list);
	printf("approved\t%s\t%s\t%s\n", entry->hash, entry->interpreter, entry->script);
	return 0;
}

static int cmd_revoke(int argc, char **argv)
{
	char script[PATH_MAX];
	const char *target = NULL;
	location_t loc;
	allowlist_t list;
	entry_t *entry;
	int system = 0;

	for (int i = 0; i < argc; i++) {
		if (strcmp(argv[i], "--system") == 0)
			system = 1;
		else if (!target)
			target = argv[i];
		else
			die(EXIT_USAGE, "revoke takes one script");
	}
	if (!target)
		die(EXIT_USAGE, "revoke needs a script. Try: maestro-run --help");
	/* A script that was deleted must still be revocable by the path given. */
	if (!realpath(target, script))
		path_join(script, sizeof script, target, "");
	resolve_location(&loc, system);
	if (loc.is_system && geteuid() != 0)
		die(EXIT_DENIED, "the system allowlist decides what runs here. Use: sudo maestro-run revoke --system '%s'",
		    script);
	load_allowlist(&loc, &list);
	entry = find_entry(&list, script);
	if (!entry)
		die(EXIT_NOT_FOUND, "%s is not on the allowlist", script);
	/* A list edited by hand can name the script twice. Remove every entry. */
	do {
		*entry = list.items[--list.count];
	} while ((entry = find_entry(&list, script)));
	save_allowlist(&loc, &list);
	printf("revoked\t%s\n", script);
	return 0;
}

static int cmd_list(void)
{
	location_t loc;
	allowlist_t list;

	resolve_location(&loc, 0);
	load_allowlist(&loc, &list);
	for (size_t i = 0; i < list.count; i++) {
		const entry_t *entry = &list.items[i];
		char actual[HASH_HEX_LEN + 1];
		const char *status = "ok";

		if (hash_file(entry->script, actual) != 0)
			status = "missing";
		else if (strcmp(actual, entry->hash) != 0)
			status = "changed";
		printf("%s\t%s\t%s\t%s\n", status, entry->hash, entry->interpreter, entry->script);
	}
	return 0;
}

static int cmd_doctor(void)
{
	char self[PATH_MAX], resolved[PATH_MAX], probe[PATH_MAX], name[PROC_PIDPATHINFO_MAXSIZE];
	uint32_t size = sizeof self;
	pid_t responsible = responsible_pid();
	const char *access_state;
	location_t loc;
	allowlist_t list;
	size_t len, suffix = strlen(BUNDLE_BINARY_SUFFIX);
	int fd;

	if (_NSGetExecutablePath(self, &size) != 0 || !realpath(self, resolved))
		path_join(resolved, sizeof resolved, "unknown", "");
	resolve_location(&loc, 0);
	load_allowlist(&loc, &list);
	path_join(probe, sizeof probe, home_dir(), TCC_PROBE_SUFFIX);
	fd = open(probe, O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		close(fd);
		access_state = "granted";
	} else {
		access_state = errno == ENOENT ? "unknown" : "not-granted";
	}

	printf("version: %s\n", MAESTRO_RUN_VERSION);
	printf("executable: %s\n", resolved);
	if (responsible == 0)
		printf("responsible-process: unknown\n");
	else if (responsible == getpid())
		printf("responsible-process: self\n");
	else if (proc_name(responsible, name, sizeof name) > 0)
		printf("responsible-process: %s (pid %d)\n", name, (int)responsible);
	else
		printf("responsible-process: pid %d\n", (int)responsible);
	printf("allowlist: %s (%s, %zu approved)\n", loc.path, loc.is_system ? "system" : "user", list.count);
	printf("full-disk-access: %s\n", access_state);
	if (strcmp(access_state, "granted") == 0)
		return 0;
	len = strlen(resolved);
	if (len > suffix && strcmp(resolved + len - suffix, BUNDLE_BINARY_SUFFIX) == 0)
		resolved[len - suffix] = '\0';
	fprintf(stderr,
		"maestro-run: add %s under System Settings > Privacy & Security > Full Disk Access, then run doctor again\n",
		resolved);
	return EXIT_NO_ACCESS;
}

static void usage(FILE *out)
{
	fputs("usage:\n"
	      "  maestro-run run <script> [args...]     run an approved script\n"
	      "  maestro-run approve [--interpreter <path>] [--system] <script>\n"
	      "                                         approve a script at its current contents\n"
	      "  maestro-run revoke [--system] <script> remove a script from the allowlist\n"
	      "  maestro-run list                       show approved scripts and whether they changed\n"
	      "  maestro-run doctor                     report identity and Full Disk Access\n"
	      "  maestro-run --version\n"
	      "\n"
	      "A script runs only while its contents match what was approved.\n"
	      "Without --interpreter the script is executed directly, so it needs a shebang.\n",
	      out);
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "";

	if (strcmp(cmd, "run") == 0 || strcmp(cmd, "doctor") == 0)
		become_responsible(argv);
	else
		unsetenv(STAGE_ENV);

	if (strcmp(cmd, "run") == 0)
		return cmd_run(argc - 2, argv + 2);
	if (strcmp(cmd, "approve") == 0)
		return cmd_approve(argc - 2, argv + 2);
	if (strcmp(cmd, "revoke") == 0)
		return cmd_revoke(argc - 2, argv + 2);
	if (strcmp(cmd, "list") == 0)
		return cmd_list();
	if (strcmp(cmd, "doctor") == 0)
		return cmd_doctor();
	if (strcmp(cmd, "--version") == 0) {
		printf("maestro-run %s\n", MAESTRO_RUN_VERSION);
		return 0;
	}
	if (strcmp(cmd, "--help") == 0 || strcmp(cmd, "-h") == 0) {
		usage(stdout);
		return 0;
	}
	usage(stderr);
	return EXIT_USAGE;
}
