/*
 * tcc-probe - report what macOS privacy services this process is allowed.
 *
 * A test helper, never shipped. scripts/tcc-matrix.sh builds it, signs it ad
 * hoc and starts it in several places to see which grants reach a child.
 *
 * It asks in two steps so that it does not raise a prompt:
 *   1. read the decision, with the status call of the service;
 *   2. touch the service, only when step 1 said "authorized".
 * Two services record a denied row for the caller when they are touched
 * without a grant: a file that needs Full Disk Access, and AXIsProcessTrusted
 * for Accessibility. For those two, step 1 is the private preflight call.
 * --control leaves both out, for a run that is expected to hold nothing.
 *
 * usage: tcc-probe [--control] [apple-event-target-bundle-id ...]
 *
 * Output: one line per check, tab separated:
 *   name, status=<...>, preflight=<...>, access=<...>
 * "preflight" is the private TCCAccessPreflight call, printed as a second
 * opinion: granted, denied, unknown, or n/a when the symbol is missing.
 */

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <Contacts/Contacts.h>
#import <CoreServices/CoreServices.h>
#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <libproc.h>
#import <pwd.h>
#import <signal.h>
#import <unistd.h>

typedef int (*preflight_fn)(CFStringRef, CFDictionaryRef);
typedef pid_t (*responsible_fn)(pid_t);

static preflight_fn tcc_preflight;

static const char *preflight(NSString *service)
{
	if (!tcc_preflight)
		return "n/a";
	switch (tcc_preflight((__bridge CFStringRef)service, NULL)) {
	case 0:
		return "granted";
	case 1:
		return "denied";
	case 2:
		return "unknown";
	default:
		return "other";
	}
}

/* Contacts, EventKit, Photos and AVFoundation share the first four values. */
static const char *status_name(NSInteger value, const char *fourth)
{
	switch (value) {
	case 0:
		return "not-determined";
	case 1:
		return "restricted";
	case 2:
		return "denied";
	case 3:
		return "authorized";
	case 4:
		return fourth;
	default:
		return "other";
	}
}

static void row(const char *name, const char *status, const char *pre, NSString *access)
{
	printf("%s\tstatus=%s\tpreflight=%s\taccess=%s\n", name, status, pre, access.UTF8String);
	fflush(stdout);
}

static void on_alarm(int sig)
{
	static const char msg[] = "timeout\tthe probe stopped: a check did not return\n";

	(void)sig;
	(void)write(STDOUT_FILENO, msg, sizeof msg - 1);
	_exit(2);
}

static void identity(void)
{
	char path[PROC_PIDPATHINFO_MAXSIZE];
	responsible_fn fn = (responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
	pid_t responsible = fn ? fn(getpid()) : 0;

	printf("pid\t%d\tppid=%d\n", (int)getpid(), (int)getppid());
	if (responsible <= 0)
		printf("responsible\tunknown\n");
	else if (proc_pidpath(responsible, path, sizeof path) > 0)
		printf("responsible\t%s\tpath=%s\n", responsible == getpid() ? "self" : "other", path);
	else
		printf("responsible\tpid-gone\n");
	fflush(stdout);
}

static void check_fda(void)
{
	struct passwd *pw = getpwuid(getuid());
	NSString *path = [NSString stringWithFormat:@"%s/Library/Application Support/com.apple.TCC/TCC.db",
						    pw ? pw->pw_dir : ""];
	const char *pre = preflight(@"kTCCServiceSystemPolicyAllFiles");
	NSString *access = @"not-attempted";

	if (strcmp(pre, "granted") == 0) {
		int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);

		access = fd >= 0 ? @"open-ok" : [NSString stringWithFormat:@"open-failed-%s", strerror(errno)];
		if (fd >= 0)
			close(fd);
	}
	row("full-disk-access", "n/a", pre, access);
}

static void check_contacts(void)
{
	NSInteger status = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
	NSString *access = @"not-attempted";

	if (status == CNAuthorizationStatusAuthorized) {
		CNContactFetchRequest *request =
			[[CNContactFetchRequest alloc] initWithKeysToFetch:@[ CNContactIdentifierKey ]];
		__block NSUInteger count = 0;
		NSError *error = nil;
		BOOL ok = [[CNContactStore new] enumerateContactsWithFetchRequest:request
									    error:&error
								       usingBlock:^(CNContact *contact, BOOL *stop) {
									       (void)contact;
									       (void)stop;
									       count++;
								       }];

		access = !ok ? [NSString stringWithFormat:@"read-failed-%ld", (long)error.code]
			     : count ? @"read-ok" : @"read-empty";
	}
	row("contacts", status_name(status, "limited"), preflight(@"kTCCServiceAddressBook"), access);
}

static void check_eventkit(const char *name, EKEntityType type, NSString *service)
{
	NSInteger status = [EKEventStore authorizationStatusForEntityType:type];
	NSString *access = @"not-attempted";

	if (status == 3)
		access = [[EKEventStore new] calendarsForEntityType:type].count ? @"read-ok" : @"read-empty";
	row(name, status_name(status, "write-only"), preflight(service), access);
}

static void check_photos(void)
{
	NSInteger status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
	NSString *access = @"not-attempted";

	if (status == PHAuthorizationStatusAuthorized)
		access = [PHAsset fetchAssetsWithOptions:nil].count ? @"read-ok" : @"read-empty";
	row("photos", status_name(status, "limited"), preflight(@"kTCCServicePhotos"), access);
}

/* Capturing would switch on the indicator in the menu bar. Status only. */
static void check_capture(const char *name, AVMediaType type, NSString *service)
{
	NSInteger status = [AVCaptureDevice authorizationStatusForMediaType:type];

	row(name, status_name(status, "other"), preflight(service), @"not-attempted");
}

static void check_accessibility(void)
{
	const char *pre = preflight(@"kTCCServiceAccessibility");
	Boolean trusted = strcmp(pre, "granted") == 0 && AXIsProcessTrusted();
	NSString *access = @"not-attempted";

	if (trusted) {
		NSRunningApplication *finder =
			[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"].firstObject;
		AXUIElementRef app = AXUIElementCreateApplication(finder.processIdentifier);
		CFTypeRef value = NULL;
		AXError error = AXUIElementCopyAttributeValue(app, kAXRoleAttribute, &value);

		access = !finder ? @"no-finder"
				 : error == kAXErrorSuccess ? @"query-ok"
							    : [NSString stringWithFormat:@"query-failed-%d", (int)error];
		if (value)
			CFRelease(value);
		CFRelease(app);
	}
	row("accessibility", trusted ? "authorized" : "not-asked", pre, access);
}

/* Without the grant macOS leaves the titles of other apps' windows out. */
static void check_screen(void)
{
	bool allowed = CGPreflightScreenCaptureAccess();
	NSString *access = @"not-attempted";

	if (allowed) {
		NSArray *windows =
			CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
		NSUInteger titled = 0;

		for (NSDictionary *window in windows) {
			if ([window[(id)kCGWindowOwnerPID] intValue] != getpid() &&
			    [window[(id)kCGWindowLayer] intValue] == 0 && [window[(id)kCGWindowName] length])
				titled++;
		}
		access = titled ? @"window-titles-visible" : @"window-titles-hidden";
	}
	row("screen-recording", allowed ? "authorized" : "denied", preflight(@"kTCCServiceScreenCapture"), access);
}

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info)
{
	(void)proxy;
	(void)type;
	(void)info;
	return event;
}

/* The tap is created and released at once. It is never added to a run loop,
 * so no event is ever delivered to this process. */
static void check_input(void)
{
	bool listen = CGPreflightListenEventAccess();
	bool post = CGPreflightPostEventAccess();
	NSString *access = @"not-attempted";

	if (listen) {
		CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
						     kCGEventTapOptionListenOnly, CGEventMaskBit(kCGEventKeyDown),
						     tap_callback, NULL);

		access = tap ? @"tap-created" : @"tap-refused";
		if (tap) {
			CFMachPortInvalidate(tap);
			CFRelease(tap);
		}
	}
	row("input-monitoring", listen ? "authorized" : "denied", preflight(@"kTCCServiceListenEvent"), access);
	row("post-event", post ? "authorized" : "denied", preflight(@"kTCCServicePostEvent"), @"not-attempted");
}

static void check_apple_events(NSString *target)
{
	NSAppleEventDescriptor *address = [NSAppleEventDescriptor descriptorWithBundleIdentifier:target];
	OSStatus status = AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, false);
	NSString *name = [@"apple-events:" stringByAppendingString:target];
	NSString *access = @"not-attempted";
	const char *text;

	switch (status) {
	case noErr:
		text = "authorized";
		break;
	case errAEEventNotPermitted:
		text = "denied";
		break;
	case errAEEventWouldRequireUserConsent:
		text = "not-determined";
		break;
	case procNotFound:
		text = "target-not-running";
		break;
	default:
		text = "other";
		break;
	}
	if (status == noErr) {
		NSString *source = [NSString stringWithFormat:@"tell application id \"%@\" to get name", target];
		NSDictionary *error = nil;

		[[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error];
		access = error ? [NSString stringWithFormat:@"send-failed-%@", error[NSAppleScriptErrorNumber]]
			       : @"send-ok";
	}
	row(name.UTF8String, text, "n/a", access);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		void *tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY);
		NSArray<NSString *> *more = @[
			@"kTCCServiceSystemPolicyDesktopFolder", @"kTCCServiceSystemPolicyDocumentsFolder",
			@"kTCCServiceSystemPolicyDownloadsFolder", @"kTCCServiceSystemPolicyNetworkVolumes",
			@"kTCCServiceSystemPolicyRemovableVolumes", @"kTCCServiceSystemPolicyAppBundles",
			@"kTCCServiceMediaLibrary", @"kTCCServiceSpeechRecognition", @"kTCCServiceBluetoothAlways",
			@"kTCCServiceDeveloperTool"
		];
		int control = 0, first = 1;

		if (argc > 1 && strcmp(argv[1], "--control") == 0) {
			control = 1;
			first = 2;
		}
		tcc_preflight = tcc ? (preflight_fn)dlsym(tcc, "TCCAccessPreflight") : NULL;
		signal(SIGALRM, on_alarm);
		alarm(45);

		identity();
		if (!control) {
			check_fda();
			check_accessibility();
		}
		check_screen();
		check_input();
		check_capture("microphone", AVMediaTypeAudio, @"kTCCServiceMicrophone");
		check_capture("camera", AVMediaTypeVideo, @"kTCCServiceCamera");
		for (int i = first; i < argc; i++)
			check_apple_events(@(argv[i]));
		check_contacts();
		check_eventkit("calendars", EKEntityTypeEvent, @"kTCCServiceCalendar");
		check_eventkit("reminders", EKEntityTypeReminder, @"kTCCServiceReminders");
		check_photos();
		for (NSString *service in more) {
			NSString *name = [service substringFromIndex:[@"kTCCService" length]];

			row(name.UTF8String, "n/a", preflight(service), @"not-attempted");
		}
		printf("done\n");
	}
	return 0;
}
