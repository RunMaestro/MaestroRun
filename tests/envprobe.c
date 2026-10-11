/* Test helper: a non-system binary, so macOS does not strip DYLD_* for us. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

int main(int argc, char **argv)
{
	const char *kept = getenv("MAESTRO_RUN_TEST_KEPT");
	const char *dyld = "unset";

	(void)argv;
	for (char **e = environ; *e; e++) {
		if (strncmp(*e, "DYLD_", 5) == 0)
			dyld = "present";
	}
	printf("dyld=%s kept=%s args=%d\n", dyld, kept ? kept : "unset", argc - 1);
	return 0;
}
