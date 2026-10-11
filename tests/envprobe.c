/* Test helper: a non-system binary, so macOS does not strip DYLD_* for us. */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	const char *dyld = getenv("DYLD_INSERT_LIBRARIES");
	const char *kept = getenv("MAESTRO_RUN_TEST_KEPT");

	printf("dyld=%s kept=%s args=%d\n", dyld ? dyld : "unset", kept ? kept : "unset", argc - 1);
	return 0;
}
