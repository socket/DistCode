//
//  AppDelegate.m
//  Distcc
//
//  Created by Mark Satterthwaite on 30/09/2013.
//  Copyright (c) 2013 marksatt. All rights reserved.
//

#import "AppDelegate.h"
#import <sys/socket.h>
#import <arpa/inet.h>
#import "OBMenuBarWindow.h"

NSNetServiceBrowser* Browser = nil;
@implementation AppDelegate

- (id)init
{
    self = [super init];
    if (self) {
        services = [[NSMutableArray alloc] init];
		DistCCServers = [NSMutableArray new];
		DistCCPipe = [NSPipe new];
		DmucsPipe = [NSPipe new];
		NSString* Path = [NSString stringWithFormat:@"%@/.dmucs", NSHomeDirectory()];
		[[NSFileManager defaultManager] createDirectoryAtPath:Path withIntermediateDirectories:NO attributes:nil error:nil];
		NSString* DistccDPath = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"distccd"];
		NSString* DmucsPath = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"dmucs"];
		DistCCDaemon = [self beginDaemonTask:DistccDPath withArguments:[NSArray arrayWithObjects:@"--daemon", @"--no-detach", @"--zeroconf", @"--allow", @"0.0.0.0/0", nil] andPipe:DistCCPipe];
		DmucsDaemon = [self beginDaemonTask:DmucsPath withArguments:[NSArray new] andPipe:DmucsPipe];
    }
    return self;
}

void *get_in_addr(struct sockaddr *sa)
{
    if (sa->sa_family == AF_INET)
        return &(((struct sockaddr_in*)sa)->sin_addr);
    return &(((struct sockaddr_in6*)sa)->sin6_addr);
}

- (void)writeDmucsHostsFile
{
	NSString* Path = [NSString stringWithFormat:@"%@/.dmucs/hosts-info", NSHomeDirectory()];
	FILE* f = fopen([Path UTF8String], "w");
	for (NSDictionary* DistCCDict in DistCCServers)
	{
		NSString* IP = [DistCCDict objectForKey:@"IP"];
		NSString* CPUs = [DistCCDict objectForKey:@"CPUS"];
		NSString* Priority = [DistCCDict objectForKey:@"PRIORITY"];
		NSString* Entry = [NSString stringWithFormat:@"%@ %@ %@\n", IP, CPUs, Priority];
		fwrite([Entry UTF8String], 1, strlen([Entry UTF8String]), f);
	}
	fclose(f);
}

- (NSTask*)beginDaemonTask:(NSString*)Path withArguments:(NSArray*)Arguments andPipe:(NSPipe*)Pipe
{
	NSTask* Task = [NSTask new];
	[Task setLaunchPath: Path];
	[Task setArguments: Arguments];
	[Task setStandardOutput: Pipe];
	[Task launch];
	return Task;
}

- (NSString*)executeTask:(NSString*)Path withArguments:(NSArray*)Arguments
{
	NSTask* Task = [[NSTask alloc] init];
	[Task setLaunchPath: Path];
	[Task setArguments: Arguments];
	
	NSPipe* Pipe = [NSPipe pipe];
	[Task setStandardOutput: Pipe];
	
	NSFileHandle* File = [Pipe fileHandleForReading];
	
	[Task launch];
	[Task waitUntilExit];
	
	NSData* Data = [File readDataToEndOfFile];
	return [[NSString alloc] initWithData: Data encoding: NSUTF8StringEncoding];
}

- (void)addDistCCServer:(NSString*)ServerIP
{
	NSString* Path = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"addhost"];
	NSString* Task = [NSString stringWithFormat:@"\"%@\" -ip %@", Path, ServerIP];
	int Err = system([Task UTF8String]);
	assert(Err == 0);
}

- (void)removeDistCCServer:(NSString*)ServerIP
{
	NSString* Path = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"remhost"];
	NSString* Task = [NSString stringWithFormat:@"\"%@\" -ip %@", Path, ServerIP];
	int Err = system([Task UTF8String]);
	assert(Err == 0);
}

// Sent when addresses are resolved
- (void)netServiceDidResolveAddress:(NSNetService *)netService
{
    // Make sure [netService addresses] contains the
    // necessary connection information
	BOOL OK = NO;
    if ([self addressesComplete:[netService addresses]
				 forServiceType:[netService type]]) {
        NSArray* Addresses = [netService addresses];
		char Name[INET6_ADDRSTRLEN];
		NSString* Path = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"distcc"];
		for (NSData* Addr in Addresses)
		{
			struct sockaddr* IP = (struct sockaddr*)[Addr bytes];
			if(inet_ntop(IP->sa_family, get_in_addr(IP), Name, INET6_ADDRSTRLEN)!=NULL)
			{
				NSString* Address = [NSString stringWithFormat:@"%s", Name];
				NSString* Response = [self executeTask:Path withArguments:[NSArray arrayWithObjects:@"--host-info", Address, nil]];
				NSArray* Components = [Response componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n="]];
				if(Components && [Components count])
				{
					NSMutableDictionary* DistCCDict = [NSMutableDictionary new];
					NSMutableArray* DistCCCompilers = [NSMutableArray new];
					NSMutableArray* DistCCSDKs = [NSMutableArray new];
					[DistCCDict setObject:DistCCCompilers forKey:@"COMPILERS"];
					[DistCCDict setObject:DistCCSDKs forKey:@"SDKS"];
					[DistCCDict setObject:netService forKey:@"SERVICE"];
					[DistCCDict setObject:Address forKey:@"IP"];
					[DistCCDict setObject:[netService hostName] forKey:@"HOSTNAME"];
					[DistCCDict setObject:[NSNumber numberWithBool:YES] forKey:@"ACTIVE"];
					[DistCCDict setObject:[[NSBundle mainBundle] imageForResource:@"mac_client-512"] forKey:@"ICON"];
					for (NSUInteger i = 0; i < [Components count]; i+=2)
					{
						NSString* Key = [Components objectAtIndex:i];
						NSString* Value = [Components objectAtIndex:i+1];
						if ([Key isCaseInsensitiveLike:@"COMPILER"])
						{
							[DistCCCompilers addObject:[NSDictionary dictionaryWithObjectsAndKeys:Value, @"name", nil]];
						}
						else if ([Key isCaseInsensitiveLike:@"SDK"])
						{
							[DistCCSDKs addObject:[NSDictionary dictionaryWithObjectsAndKeys:Value, @"name", nil]];
						}
						else if(Key && [Key length] > 0 && Value && [Value length] > 0)
						{
							[DistCCDict setObject:Value forKey:Key];
						}
					}
//					[DistCCServerController addObject:DistCCDict];
					[DistCCServerController insertObject:DistCCDict atArrangedObjectIndex:[services indexOfObject:netService]];
					[self writeDmucsHostsFile];
					[self addDistCCServer:Address];
					OK = YES;
					break;
				}
			}
		}
    }
	if(OK == NO)
	{
		[services removeObject:netService];
	}
}

// Sent if resolution fails
- (void)netService:(NSNetService *)netService didNotResolve:(NSDictionary *)errorDict
{
    [self handleError:[errorDict objectForKey:NSNetServicesErrorCode] withService:netService];
	NSUInteger Index = [services indexOfObject:netService];
	if(Index != NSNotFound)
	{
		if([DistCCServers count] > Index)
		{
			NSMutableDictionary* DistCCDict = [DistCCServers objectAtIndex:Index];
			if(DistCCDict && [[DistCCDict objectForKey:@"SERVICE"] isEqualTo:netService])
			{
				[self removeDistCCServer:[DistCCDict objectForKey:@"IP"]];
				[DistCCServerController removeObject:DistCCDict];
				[self writeDmucsHostsFile];
			}
		}
		[services removeObject:netService];
	}
}

// Verifies [netService addresses]
- (BOOL)addressesComplete:(NSArray *)addresses forServiceType:(NSString *)serviceType
{
    // Perform appropriate logic to ensure that [netService addresses]
    // contains the appropriate information to connect to the service
    return YES;
}

// Error handling code
- (void)handleError:(NSNumber *)error withService:(NSNetService *)service
{
    NSLog(@"An error occurred with service %@.%@.%@, error code = %d",
		  [service name], [service type], [service domain], [error intValue]);
    // Handle error here
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	// Insert code here to initialize your application
	NSImage* Image = [NSImage imageNamed:@"vpn-512"];
	[Image setSize:NSMakeSize(22.f, 22.f)];
    self.window.menuBarIcon = Image;
    self.window.highlightedMenuBarIcon = Image;
    self.window.hasMenuBarIcon = YES;
    self.window.attachedToMenuBar = YES;
    self.window.isDetachable = YES;
	Browser = [[NSNetServiceBrowser alloc] init];
	[Browser setDelegate:self];
	[Browser searchForServicesOfType:@"_xcodedistcc._tcp" inDomain:@""];
}
- (void)applicationWillTerminate:(NSNotification *)notification
{
	[Browser stop];
	Browser = nil;
	[DistCCDaemon terminate];
	[DmucsDaemon terminate];
	[DistCCDaemon waitUntilExit];
	[DmucsDaemon waitUntilExit];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser didFindDomain:(NSString *)domainName moreComing:(BOOL)moreDomainsComing
{
	
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser didRemoveDomain:(NSString *)domainName moreComing:(BOOL)moreDomainsComing
{
	
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser didFindService:(NSNetService *)netService moreComing:(BOOL)moreServicesComing
{
	[services addObject:netService];
	[netService setDelegate:self];
	[netService scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
	[netService resolveWithTimeout:15.0];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser didRemoveService:(NSNetService *)netService moreComing:(BOOL)moreServicesComing
{
	NSUInteger Index = [services indexOfObject:netService];
	if(Index != NSNotFound)
	{
		if([DistCCServers count] > Index)
		{
			NSMutableDictionary* DistCCDict = [DistCCServers objectAtIndex:Index];
			if(DistCCDict && [[DistCCDict objectForKey:@"SERVICE"] isEqualTo:netService])
			{
				[self removeDistCCServer:[DistCCDict objectForKey:@"IP"]];
				[DistCCServerController removeObject:DistCCDict];
				[self writeDmucsHostsFile];
			}
		}
		[services removeObject:netService];
	}
}
- (void)netServiceBrowserWillSearch:(NSNetServiceBrowser *)netServiceBrowser
{
	
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser didNotSearch:(NSDictionary *)errorInfo
{
	
}
- (void)netServiceBrowserDidStopSearch:(NSNetServiceBrowser *)netServiceBrowser
{
	
}
@end