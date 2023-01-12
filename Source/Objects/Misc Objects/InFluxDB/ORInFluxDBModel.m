//
//  ORInFluxDBModel.m
//  Orca
//
//  Created by Mark Howe on 12/7/2022.
//  Copyright 2006 CENPA, University of Washington. All rights reserved.
//-----------------------------------------------------------
//This program was prepared for the Regents of the University of
//Washington at the Center for Experimental Nuclear Physics and
//Astrophysics (CENPA) sponsored in part by the United States
//Department of Energy (DOE) under Grant #DE-FG02-97ER41020.
//The University has certain rights in the program pursuant to
//the contract and the program should not be copied or distributed
//outside your organization.  The DOE and the University of
//Washington reserve all rights in the program. Neither the authors,
//University of Washington, or U.S. Government make any warranty,
//express or implied, or assume any liability or responsibility
//for the use of this software.
//-------------------------------------------------------------

#import "ORInFluxDBModel.h"
#import "ORInFluxDBCmd.h"
#import "MemoryWatcher.h"
#import "ORAppDelegate.h"
#import "NSNotifications+Extensions.h"
#import "Utilities.h"
#import "ORSafeQueue.h"
#import "ORExperimentModel.h"
#import "ORAlarmCollection.h"
#import "ORAlarm.h"
#import "OR1DHisto.h"
#import "ORProcessModel.h"
#import "ORProcessElementModel.h"
#import "ORRunModel.h"
#import "ORSegmentGroup.h"
#import "ORDetectorSegment.h"
#import "ORTimeRate.h"
#import <ifaddrs.h>
#import <arpa/inet.h>

NSString* ORInFluxDBPortNumberChanged      = @"ORInFluxDBPortNumberChanged";
NSString* ORInFluxDBAuthTokenChanged       = @"ORInFluxDBAuthTokenChanged";
NSString* ORInFluxDBOrgChanged             = @"ORInFluxDBOrgChanged";
NSString* ORInFluxDBBucketChanged          = @"ORInFluxDBBucketChanged";
NSString* ORInFluxDBHostNameChanged        = @"ORInFluxDBHostNameChanged";
NSString* ORInFluxDBModelDBInfoChanged     = @"ORInFluxDBModelDBInfoChanged";
NSString* ORInFluxDBRateChanged            = @"ORInFluxDBRateChanged";
NSString* ORInFluxDBStealthModeChanged     = @"ORInFluxDBStealthModeChanged";
NSString* ORInFluxDBBucketArrayChanged     = @"ORInFluxDBBucketArrayChanged";
NSString* ORInFluxDBOrgArrayChanged        = @"ORInFluxDBOrgArrayChanged";

NSString* ORInFluxDBLock                   = @"ORInFluxDBLock";

static NSString* ORInFluxDBModelInConnector = @"ORInFluxDBModelInConnector";

@interface ORInFluxDBModel (private)
- (void) updateProcesses;
- (void) updateExperimentMetrics;
- (void) updateHistory;
- (void) updateMachineRecord;
- (void) updateRunState:(ORRunModel*)rc;
- (void) processElementStateChanged:(NSNotification*)aNote;
- (void) periodicCompact;
- (void) updateDataSets;
- (void) _cancelAllPeriodicOperations;
- (void) _startAllPeriodicOperations;
- (void) decodeBucketList:(NSDictionary*)result;
- (void) decodeOrgList   :(NSDictionary*)result;
@end

@implementation ORInFluxDBModel

#pragma mark ***Initialization

- (id) init
{
    self = [super init];
    return self;
}

- (void) dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [hostName        release];
    [processThread   release];
    [authToken       release];;
    [org             release];
    [thisHostAddress release];
    [bucketArray     release];
    [orgArray        release];
    [timer           invalidate];
    [timer           release];
    [experimentName  release];
    [runNumberString release];
    [super dealloc];
}

- (void) wakeUp
{
    if(![self aWake]){
        [self connectionChanged];
        [self _startAllPeriodicOperations];
        [self registerNotificationObservers];
        [self executeDBCmd:[ORInFluxDBListOrgs    listOrgs]];
        [self executeDBCmd:[ORInFluxDBDelayCmd    delay:2]];
        [self executeDBCmd:[ORInFluxDBListBuckets listBuckets]];
        [self cleanUpRunStatus];

    }
    [super wakeUp];
}

- (void) sleep
{
    canceled = YES;
    [self _cancelAllPeriodicOperations];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super sleep];
}

- (void) setUpImage
{
    [self setImage:[NSImage imageNamed:@"InFlux"]];
}

- (void) makeMainController
{
    [self linkToController:@"ORInFluxDBController"];
}

- (void) makeConnectors
{
    ORConnector* aConnector = [[ORConnector alloc] initAt:NSMakePoint(0,[self frame].size.height/2-kConnectorSize/2) withGuardian:self withObjectLink:self];
    [[self connectors] setObject:aConnector forKey:ORInFluxDBModelInConnector];
    [aConnector setOffColor:[NSColor brownColor]];
    [aConnector setOnColor:[NSColor magentaColor]];
    [aConnector setConnectorType: 'DB I' ];
    [aConnector addRestrictedConnectionType: 'DB O' ]; //can only connect to DB outputs
    
    [aConnector release];
}

- (void) connectionChanged
{
    [self setExperimentName: [[self nextObject] objectName]];
}

- (void) registerNotificationObservers
{
    NSNotificationCenter* notifyCenter = [NSNotificationCenter defaultCenter];
    
    [notifyCenter removeObserver:self];
    
    [notifyCenter addObserver : self
                     selector : @selector(applicationIsTerminating:)
                         name : @"ORAppTerminating"
                       object : (ORAppDelegate*)[NSApp delegate]];
    
    [notifyCenter addObserver : self
                     selector : @selector(runStarted:)
                         name : ORRunStartedNotification
                       object : nil];
    
    [notifyCenter addObserver : self
                     selector : @selector(runStarted:)
                         name : ORRunStartSubRunNotification
                       object : nil];
    
    [notifyCenter addObserver : self
                     selector : @selector(runStopped:)
                         name : ORRunBetweenSubRunsNotification
                       object : nil];
    

    [notifyCenter addObserver : self
                     selector : @selector(runStopped:)
                         name : ORRunStoppedNotification
                       object : nil];

    [notifyCenter addObserver : self
                     selector : @selector(runStatusChanged:)
                         name : ORRunStatusChangedNotification
                       object : nil];

    [notifyCenter addObserver : self
                     selector : @selector(runElapsedTimeChanged:)
                         name : ORRunElapsedTimesChangedNotification
                       object : nil];
    
    [notifyCenter addObserver : self
                     selector : @selector(alarmPosted:)
                         name : ORAlarmWasPostedNotification
                       object : nil];

    [notifyCenter addObserver : self
                     selector : @selector(alarmAcknowledged:)
                         name : ORAlarmWasAcknowledgedNotification
                       object : nil];
    
    [notifyCenter addObserver : self
                     selector : @selector(alarmCleared:)
                         name : ORAlarmWasClearedNotification
                       object : nil];
        
    [notifyCenter addObserver : self
                     selector : @selector(updateProcesses)
                         name : ORProcessRunningChangedNotification
                       object : nil];
    
    [notifyCenter addObserver : self
                     selector : @selector(processElementStateChanged:)
                         name : ORProcessElementStateChangedNotification
                       object : nil];
}

- (void) applicationIsTerminating:(NSNotification*)aNote
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
 }

- (void) awakeAfterDocumentLoaded
{
    [self startTimer];
}

#pragma mark ***Accessors
- (id) nextObject
{
    return [self objectConnectedTo:ORInFluxDBModelInConnector];
}
- (NSString*) experimentName
{
    return experimentName;
}

- (void) setExperimentName:(NSString*)aName
{
    [experimentName autorelease];
    experimentName = [aName copy];
}

- (NSUInteger) portNumber
{
    return portNumber;
}

- (void) setPortNumber:(NSUInteger)aPort
{
    [[[self undoManager] prepareWithInvocationTarget:self] setPortNumber:portNumber];
    if(aPort == 0)aPort = 8086;
    portNumber = aPort;
    [[NSNotificationCenter defaultCenter] postNotificationName:ORInFluxDBPortNumberChanged object:self];
}

- (NSString*) hostName
{
    return hostName;
}

- (void) setHostName:(NSString*)aHostName
{
    if(!aHostName)aHostName = @"";
    [[[self undoManager] prepareWithInvocationTarget:self] setHostName:hostName];
    
    [hostName autorelease];
    hostName = [aHostName copy];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:ORInFluxDBHostNameChanged object:self];
}

- (NSString*) authToken
{
    return authToken;
}

- (void) setAuthToken:(NSString*)aAuthToken
{
    if(!aAuthToken)aAuthToken = @"";
    [[[self undoManager] prepareWithInvocationTarget:self] setAuthToken:authToken ];
    
    [authToken autorelease];
    authToken = [aAuthToken copy];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:ORInFluxDBAuthTokenChanged object:self];
}

- (NSString*) org
{
    return org;
}

- (void) setOrg:(NSString*)anOrg
{
    if(!anOrg)anOrg = @"";
    [[[self undoManager] prepareWithInvocationTarget:self] setOrg:org ];
    
    [org autorelease];
    org = [anOrg copy];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:ORInFluxDBOrgChanged object:self];
}

- (BOOL) stealthMode
{
    return stealthMode;
}

- (void) setStealthMode:(BOOL)aStealthMode
{
    [[[self undoManager] prepareWithInvocationTarget:self] setStealthMode:stealthMode];
    stealthMode = aStealthMode;
    if(stealthMode){
        [self _cancelAllPeriodicOperations];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ORInFluxDBStealthModeChanged object:self];
}

- (void) startTimer
{
    [timer invalidate];
    [timer release];
    timer = [[NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(calcRate)userInfo:nil repeats:YES] retain];
}

- (void) calcRate
{
    messageRate = totalSent;
    totalSent = 0;
    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:ORInFluxDBRateChanged object:self];
}

- (NSInteger) messageRate        { return messageRate; }
- (BOOL)      cancelled       { return canceled; }
- (void)      markAsCanceled  { canceled = YES;  }


#pragma mark ***Measurements
- (void) sendCmd:(ORInFluxDBCmd*)aCmd
{
    if(!processThread){
        processThread = [[NSThread alloc] initWithTarget:self selector:@selector(sendMeasurments) object:nil];
        [processThread start];
    }
    if(!messageQueue){
        messageQueue = [[ORSafeQueue alloc] init];
    }
    [messageQueue enqueue:aCmd];
}

- (void) alarmPosted:(NSNotification*)aNote
{
    if(!stealthMode){
        ORAlarm* alarm = [aNote object];
        NSString* alarmName = [[alarm name]stringByReplacingOccurrencesOfString:@" " withString:@"_"];
        ORInFluxDBMeasurement* aCmd = [ORInFluxDBMeasurement measurementForBucket:@"Alarms" org:org];
        [aCmd   start  : alarmName       withTags:@"Type=CurrentAlarm"];
        [aCmd addString: @"Severity"     withValue:[alarm severityName]];
        [aCmd addString: @"Acknowledged" withValue:@"NO"];
        [aCmd addString: @"Posted"       withValue:[alarm timePosted]];
        [self executeDBCmd:aCmd];
     }
}

- (void) alarmAcknowledged:(NSNotification*)aNote
{
    if(!stealthMode){
        ORAlarm* alarm = [aNote object];
        NSString* alarmName = [[alarm name]stringByReplacingOccurrencesOfString:@" " withString:@"_"];
        [self deleteAlarm:alarmName];
        ORInFluxDBMeasurement* aCmd = [ORInFluxDBMeasurement measurementForBucket:@"Alarms" org:org];
        [aCmd     start: alarmName       withTags:@"Type=CurrentAlarm"];
        [aCmd addString: @"Severity"     withValue:[alarm severityName]];
        [aCmd addString: @"Acknowledged" withValue:@"YES"];
        [aCmd addString: @"Posted"       withValue:[alarm timePosted]];
        [self executeDBCmd:aCmd];
      }
}

- (void) alarmCleared:(NSNotification*)aNote
{
    ORAlarm* alarm = [aNote object];
    NSString* alarmName = [[alarm name]stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    [self deleteAlarm:alarmName];
    ORInFluxDBMeasurement* aCmd = [ORInFluxDBMeasurement measurementForBucket:@"Alarms" org:org];
    [aCmd     start: @"AlarmHistory"  withTags:@"Type=List"];
    [aCmd addString: @"Severity"      withValue:[alarm severityName]];
    [aCmd addString: @"Alarm"         withValue:alarmName];
    [aCmd addString: @"Posted"        withValue:[alarm timePosted]];
    [aCmd addString: @"Cleared"       withValue:[[NSDate date]stdDescription]];
    [self executeDBCmd:aCmd];
}

- (void) deleteAlarm:(NSString*)name
{
    NSDate* slightlyInFuture = [NSDate dateWithTimeIntervalSinceNow:+2];
    NSString* pred = [NSString stringWithFormat:@"_measurement=\"%@\"",name];
    ORInFluxDBDeleteSelectedData* aCmd = [ORInFluxDBDeleteSelectedData deleteSelectedData:@"Alarms"
                                                                                      org:org
                                                                                    start:@"2023-01-01T00:00:00Z"
                                                                                     stop:[NSDate dateInRFC3339Format:slightlyInFuture]
                                                                                predicate:pred];
    [self executeDBCmd:aCmd];
}

- (void) updateRunInfo
{
    if(!stealthMode){
        NSArray* runObjects = [[self document] collectObjectsOfClass:NSClassFromString(@"ORRunModel")];
        if([runObjects count]){
            ORRunModel* rc = [runObjects objectAtIndex:0];
            if(rc)[self updateRunState:rc];
        }
    }
}

- (void) updateRunState:(ORRunModel*)rc
{
    scheduledForRunInfoUpdate = NO;

    if(!stealthMode){
        ORInFluxDBMeasurement* aCmd = [ORInFluxDBMeasurement measurementForBucket:@"ORCA" org:org];
        [aCmd   start:   @"CurrentRun"  withTags:@"Type=Status"];
        [aCmd addString: @"Number"      withValue:[rc fullRunNumberString]];
        [aCmd addString: @"State"       withValue:[rc shortStatus]];
        [aCmd addLong:   @"ElapsedTime" withValue:[rc elapsedRunTime]];
        [aCmd addLong:   @"TimeToGo"    withValue:(long)[rc timeToGo]];
        [aCmd addLong:   @"RunType"     withValue:[rc runType]];
        [aCmd addString: @"TimedRun"    withValue:[rc timedRun]?@"YES":@"NO"];
        [aCmd addString: @"RunMode"     withValue:[[ORGlobal sharedGlobal] runMode] == kNormalRun?@"Normal":@"OffLine"];
        if([rc timedRun]){
            [aCmd addString: @"Repeating" withValue:[rc repeatRun]?@"Yes":@"No"];
            [aCmd addLong:   @"Length"  withValue:[rc timeLimit]];
        }
        [aCmd addString:   @"StartTime"  withValue:[[rc startTime]stdDescription]];
        
        [self executeDBCmd:aCmd];
    }
}

- (void) runStatusChanged:(NSNotification*)aNote
{
    [self updateRunState:[aNote object]];
    //[self updateDataSets];
}

- (void) cleanUpRunStatus
{
    //delete/cleanup the running status records. No need to keep.
    ORInFluxDBDeleteSelectedData* aDeleteCmd;
    NSDate* slightlyInFuture = [NSDate dateWithTimeIntervalSinceNow:+2];
    aDeleteCmd = [ORInFluxDBDeleteSelectedData deleteSelectedData:@"ORCA"
                                                              org:org
                                                            start:@"2023-01-01T00:00:00Z"
                                                             stop:[NSDate dateInRFC3339Format:slightlyInFuture]
                                                        predicate:@"_measurement=\"CurrentRun\""];
      [self executeDBCmd:aDeleteCmd];
}

- (void) runStarted:(NSNotification*)aNote
{
    if(!stealthMode){
        [self cleanUpRunStatus];
        ORRunModel* rc  = [aNote object];
        [self updateRunState:rc];
        [runNumberString release];
        runNumberString = [rc fullRunNumberString];
        [self updateExperimentMetrics];
    }
}

- (void) runStopped:(NSNotification*)aNote
{
    [runNumberString release];
    runNumberString = nil;

    if(!stealthMode){
        [self updateRunState:[aNote object]];
        ORRunModel* rc  = [aNote object];
        //keep a record of all runs
        if([[ORGlobal sharedGlobal] runMode] == kNormalRun){
            ORInFluxDBMeasurement* aCmd = [ORInFluxDBMeasurement measurementForBucket:@"ORCA" org:org];
            [aCmd     start: @"RunHistory"  withTags:@"Type=List"];
            [aCmd addString: @"Number"      withValue:[rc fullRunNumberString]];
            [aCmd   addLong: @"RunType"     withValue:[rc runType]];
            [aCmd addDouble: @"Length"      withValue:[rc elapsedRunTime]];
            [aCmd addString: @"StopTime"    withValue:[[NSDate date] stdDescription]];
            [aCmd addString: @"StartTime"   withValue:[[rc startTime]stdDescription]];
            [self executeDBCmd:aCmd];
        }
    }
}

- (void) runElapsedTimeChanged:(NSNotification*)aNote
{
    if(!scheduledForRunInfoUpdate){
        scheduledForRunInfoUpdate = YES;
        [self performSelector:@selector(updateRunState:) withObject:[aNote object] afterDelay:5];
    }
}

- (void) executeDBCmd:(id)aCmd
{
    [aCmd executeCmd:self];
}

- (NSString*) orgId
{
    for(id anOrg in orgArray){
        if([[anOrg objectForKey:@"name"] isEqualToString:org]){
            return [anOrg objectForKey:@"id"];
        }
    }
    return @"";
}

- (void) deleteBucket:(NSInteger)index
{
    NSDictionary* bucketInfo   = [bucketArray objectAtIndex:index];
    NSString*      aBucketId   = [bucketInfo objectForKey:@"id"];
    if(aBucketId){
        ORInFluxDBDeleteBucket* aCmd = [ORInFluxDBDeleteBucket deleteBucket];
        [aCmd setBucketId:[bucketInfo objectForKey:@"id"]];
        [self executeDBCmd:aCmd];
        [self performSelector:@selector(executeDBCmd:) withObject:[ORInFluxDBListBuckets listBuckets] afterDelay:2];
        NSLog(@"Posting Delete Bucket %@:%@\n",[bucketInfo objectForKey:@"name"],[self org]);
    }
}

- (void) deleteBucketByName:(NSString*)aName
{
    for(id aBucket in bucketArray){
        if([[aBucket objectForKey:@"name"]isEqualToString:aName]){
            ORInFluxDBDeleteBucket* aCmd = [ORInFluxDBDeleteBucket deleteBucket];
            [aCmd setBucketId:[aBucket objectForKey:@"id"]];
            [self executeDBCmd:aCmd];
            [self performSelector:@selector(executeDBCmd:) withObject:[ORInFluxDBListBuckets listBuckets] afterDelay:2];
        }
    }
}
- (void) createBuckets
{
    if(experimentName){
        [self executeDBCmd:[ORInFluxDBCreateBucket createBucket:experimentName
                                                          orgId:[self orgId] expireTime:0]];
    }
    [self executeDBCmd:[ORInFluxDBCreateBucket createBucket:@"ORCA"
                                                      orgId:[self orgId] expireTime:60*60*24*60]];
    [self executeDBCmd:[ORInFluxDBCreateBucket createBucket:@"Sensors"
                                                      orgId:[self orgId] expireTime:60*60*24*60]];
    [self executeDBCmd:[ORInFluxDBCreateBucket createBucket:@"Computer"
                                                      orgId:[self orgId] expireTime:60*60*24*10]];
    [self executeDBCmd:[ORInFluxDBCreateBucket createBucket:@"Alarms"
                                                      orgId:[self orgId] expireTime:0]];

    [self performSelector:@selector(executeDBCmd:) withObject:[ORInFluxDBListBuckets listBuckets] afterDelay:1];
}

#pragma mark ***Archival
- (id)initWithCoder:(NSCoder*)decoder
{
    self = [super initWithCoder:decoder];
    [[self undoManager]  disableUndoRegistration];
    [self setHostName:   [decoder decodeObjectForKey    : @"HostName"]];
    [self setPortNumber: [decoder decodeIntegerForKey   : @"PortNumber"]];
    [self setAuthToken:  [decoder decodeObjectForKey    : @"Token"]];
    [self setOrg:        [decoder decodeObjectForKey    : @"Org"]];
    [self setExperimentName: [decoder decodeObjectForKey: @"experimentName"]];
    [[self undoManager]  enableUndoRegistration];
    [self registerNotificationObservers];
    return self;
}

- (void)encodeWithCoder:(NSCoder*)encoder
{
    [super encodeWithCoder:encoder];
    [encoder encodeInteger:portNumber    forKey: @"PortNumber"];
    [encoder encodeObject:hostName       forKey: @"HostName"];
    [encoder encodeObject:authToken      forKey: @"Token"];
    [encoder encodeObject:org            forKey: @"Org"];
    [encoder encodeObject:experimentName forKey: @"experimentName"];
}

- (void) _cancelAllPeriodicOperations
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void) _startAllPeriodicOperations
{
    [self performSelector:@selector(updateMachineRecord) withObject:nil afterDelay:2];
    [self performSelector:@selector(updateExperimentRates)         withObject:nil afterDelay:3];
    [self performSelector:@selector(updateRunInfo)       withObject:nil afterDelay:4];
}

- (void) updateMachineRecord
{
    if(!stealthMode){
        @try {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateMachineRecord) object:nil];
 
            [self updateMachineAddress];
            [self updateOrcaResources];
            [self updateDiskInfo];
        }
        @catch (NSException* e){
            NSLog(@"%@ %@ Exception: %@\n",[self fullID],NSStringFromSelector(_cmd),e);
        }
        @finally {
            [self performSelector:@selector(updateMachineRecord) withObject:nil afterDelay:60];
        }
    }
}

- (void) updateOrcaResources
{
    long uptime = [[(ORAppDelegate*)(ORAppDelegate*)[NSApp delegate] memoryWatcher] upTime];
    long memory = [[(ORAppDelegate*)(ORAppDelegate*)[NSApp delegate] memoryWatcher] orcaMemory];
    
    ORInFluxDBMeasurement* aMeasurement;
    aMeasurement  = [ORInFluxDBMeasurement measurementForBucket:@"ORCA" org:org];
    [aMeasurement start:@"ORCAStatus" withTags:@"Type=Resources"];
    [aMeasurement addLong:@"Uptime" withValue:uptime];
    [aMeasurement addLong:@"Memory" withValue:memory];
    [self executeDBCmd:aMeasurement];
}

- (void) updateDiskInfo
{
    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray* diskInfo = [fm mountedVolumeURLsIncludingResourceValuesForKeys:0 options:NSVolumeEnumerationSkipHiddenVolumes];
    for(id aVolume in diskInfo){
        NSError *fsError = nil;
        aVolume = [aVolume relativePath];
        NSDictionary *fsDictionary = [fm attributesOfFileSystemForPath:aVolume error:&fsError];
        
        if (fsDictionary != nil){
            //if([aVolume rangeOfString:@"Volumes"].location !=NSNotFound){
            // aVolume = [aVolume substringFromIndex:9];
            double freeSpace   = [[fsDictionary objectForKey:@"NSFileSystemFreeSize"] doubleValue]/1E9;
            double totalSpace  = [[fsDictionary objectForKey:@"NSFileSystemSize"] doubleValue]/1E9;
            double percentUsed = 100*(totalSpace-freeSpace)/totalSpace;
            ORInFluxDBMeasurement* aMeasurement  = [ORInFluxDBMeasurement measurementForBucket:@"Computer" org:org];
            [aMeasurement start:@"DiskInfo" withTags:[NSString stringWithFormat:@"Disk=%@",aVolume]];
            [aMeasurement addDouble:@"FreeSpace"   withValue:freeSpace];
            [aMeasurement addDouble:@"TotalSpace"  withValue:totalSpace];
            [aMeasurement addDouble:@"PercentUsed" withValue:percentUsed];
            [self executeDBCmd:aMeasurement];
        }
    }
}

- (void) updateMachineAddress
{
    //only have to get this once
    struct ifaddrs *ifaddr, *ifa;
    if (getifaddrs(&ifaddr) == 0) {
        // Successfully received the structs of addresses.
        char tempInterAddr[INET_ADDRSTRLEN];
        NSMutableArray* names = [NSMutableArray array];
        // The following is a replacement for [[NSHost currentHost] addresses].  The problem is
        // that the NSHost call can do reverse DNS calls which block and are *very* slow.  The
        // following is much faster.
        for (ifa = ifaddr; ifa != nil; ifa = ifa->ifa_next) {
            // skip IPv6 addresses
            if (ifa->ifa_addr->sa_family != AF_INET) continue;
            inet_ntop(AF_INET,
                      &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr,
                      tempInterAddr,
                      sizeof(tempInterAddr));
            [names addObject:[NSString stringWithCString:tempInterAddr encoding:NSASCIIStringEncoding]];
        }
        freeifaddrs(ifaddr);
        // Now enumerate and find the first non-loop-back address.
        NSEnumerator* e = [names objectEnumerator];
        id aName;
        while(aName = [e nextObject]){
            if([aName rangeOfString:@".0.0."].location == NSNotFound){
                thisHostAddress = [aName copy];
                break;
            }
        }
    }
    
    if(thisHostAddress){
        ORInFluxDBMeasurement* aMeasurement = [ORInFluxDBMeasurement measurementForBucket:@"Computer" org:org];
        [aMeasurement start:@"Identity" withTags:[NSString stringWithFormat:@"Name=%@",computerName()]];
        [aMeasurement addString:@"hwAddress" withValue:macAddress()];
        [aMeasurement addString:@"ipAddress" withValue:thisHostAddress];
        [self executeDBCmd:aMeasurement];
    }
}

- (void) updateExperimentMetrics
{
    if(!stealthMode && runNumberString!=nil){
        @try {
            ORExperimentModel* experiment = [self nextObject];
            int numGroups = [experiment numberOfSegmentGroups];
            for(int aSet=0;aSet<numGroups;aSet++){
                ORSegmentGroup* segmentGroup = [experiment segmentGroup:aSet];
                int numSegments = [experiment numberSegmentsInGroup:aSet];
                ORInFluxDBMeasurement* aCmd = [ORInFluxDBMeasurement measurementForBucket:experimentName org:org];
                for(int i = 0; i<numSegments; i++){
                    ORDetectorSegment* aSegment = [segmentGroup segment:i];
                    NSString* tags = [NSString stringWithFormat:@"groupName = %@,runNumber=%@,crate=%d,card=%d,chan=%d",
                                      [segmentGroup groupName],runNumberString,[aSegment crateNumber],[aSegment cardSlot],[aSegment channel]];
                    [aCmd start  :@"Metrics"      withTags:tags];
                    [aCmd addLong:@"Threshold"  withValue:[segmentGroup getThreshold:i]];
                    [aCmd addLong:@"Online"     withValue:[segmentGroup online:i]];
                    [aCmd addLong:@"Gain"       withValue:[segmentGroup getGain:i]];
                    [self executeDBCmd:aCmd];
                }
                
                //NSArray* mapEntries = [[segmentGroup paramsAsString] componentsSeparatedByString:@"\n"];
                //if([mapEntries count])      [aDictionary setObject:mapEntries       forKey: @"geometry"];
                
                
                
                //            NSArray* totalRateArray = [[[experiment segmentGroup:aSet] totalRate] ratesAsArray];
                //            if(totalRateArray)[aDictionary setObject:totalRateArray forKey:@"totalRate"];
                //
                //            [values setObject:aDictionary forKey:[segmentGroup groupName]];
            }
            
            //        NSMutableDictionary* aDictionary= [NSMutableDictionary dictionary];
            //        NSArray* stringMapEntries = [[self stringMapFileAsString] componentsSeparatedByString:@"\n"];
            //        [aDictionary setObject:stringMapEntries forKey: @"geometry"];
            //        [values setObject:aDictionary           forKey:@"Strings"];
            //
            //        aDictionary= [NSMutableDictionary dictionary];
            //        NSArray* specialMapEntries = [[self specialMapFileAsString] componentsSeparatedByString:@"\n"];
            //        [aDictionary setObject:specialMapEntries forKey: @"list"];
            //        [values setObject:aDictionary           forKey:@"SpecialChannels"];
        }
        @catch(NSException* e){
            
        }
    }
}

- (void) updateExperimentRates
{
    if(!stealthMode && runNumberString!=nil){
        @try {
            ORExperimentModel* experiment = [self nextObject];
            int numGroups = [experiment numberOfSegmentGroups];
            for(int aSet=0;aSet<numGroups;aSet++){
                ORSegmentGroup* segmentGroup = [experiment segmentGroup:aSet];
                int numSegments = [experiment numberSegmentsInGroup:aSet];
                ORInFluxDBMeasurement* aCmd = [ORInFluxDBMeasurement measurementForBucket:experimentName org:org];
                for(int i = 0; i<numSegments; i++){
                    ORDetectorSegment* aSegment = [segmentGroup segment:i];
                    NSString* tags = [NSString stringWithFormat:@"groupName = %@,runNumber=%@,crate=%d,card=%d,chan=%d",
                                      [segmentGroup groupName],runNumberString,[aSegment crateNumber],[aSegment cardSlot],[aSegment channel]];
                    [aCmd start:@"Metrics"      withTags:tags];
                    [aCmd addLong:@"TotalCount" withValue:[segmentGroup getTotalCounts:i]];
                    [aCmd addLong:@"Rate"       withValue:[segmentGroup getRate:i]];
                    [self executeDBCmd:aCmd];
                }
            }
        }
        @catch(NSException* e){
            
        }
        @finally{
            [self performSelector:@selector(updateExperimentRates) withObject:nil afterDelay:60];
        }
    }
}
- (NSArray*) bucketArray
{
    return bucketArray;
}

- (NSArray*) orgArray
{
    return orgArray;
}

- (void) decodeBucketList:(NSDictionary*)result
{
    NSArray* anArray = [result objectForKey:@"buckets"];
    [bucketArray release];
    bucketArray = [[NSMutableArray array] retain];
    for(NSDictionary* aBucket in anArray){
        if(![[aBucket objectForKey:@"name"] hasPrefix:@"_"]){
            [bucketArray addObject:aBucket];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:ORInFluxDBBucketArrayChanged
                                    object:self
                                  userInfo:nil
                             waitUntilDone:NO];
    [self printBucketTable];
}

- (void) decodeOrgList:(NSDictionary*)result
{
    NSArray* anArray = [result objectForKey:@"orgs"];
    if([anArray count]){
        [orgArray release];
        orgArray = [anArray retain];
    }
    else {
        [orgArray release];
        orgArray = nil;
    }
    [[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:ORInFluxDBOrgArrayChanged
                                                                        object:self
                                                                      userInfo:nil
                                                                 waitUntilDone:NO];
    [self printOrgTable];
}

- (void) printBucketTable
{
    if(bucketArray){
        NSString* title = [NSString stringWithFormat:@"InfluxDB Buckets (%@)",org];
        int width = 37;
        NSLogStartTable(title, width);
        NSLogMono(@"|      name    |         ID         |\n");
        NSLogDivider(@"-",width);
        for(id aBucket in bucketArray){
            NSLogMono(@"| %@ | %@ |\n", [[aBucket objectForKey:@"name"] leftJustified:12],[[aBucket objectForKey:@"id"]leftJustified:18]);
        }
        NSLogDivider(@"=",width);
    }
    else NSLog(@"No buckets found for UNC\n");
}
- (void) printOrgTable
{
    if(orgArray){
        NSString* title = @"InfluxDB Orgs";
        int width = 37;
        NSLogStartTable(title, width);
        NSLogMono(@"|      name    |         ID         |\n");
        NSLogDivider(@"-",width);
        for(id anOrg in orgArray){
            NSLogMono(@"| %@ | %@ |\n", [[anOrg objectForKey:@"name"] leftJustified:12],[[anOrg objectForKey:@"id"]leftJustified:18]);
        }
        NSLogDivider(@"=",width);
    }
    else NSLog(@"No organizations found\n");
}
#pragma mark ***Thread
- (void)sendMeasurments
{
    NSAutoreleasePool* outerPool = [[NSAutoreleasePool alloc] init];
    if(!messageQueue){
        messageQueue = [[ORSafeQueue alloc] init];
    }

    do {
        NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
        id     aCmd = [messageQueue dequeue];
        if([aCmd isKindOfClass:NSClassFromString(@"ORInFluxDBDelayCmd")]){
            [ORTimer delay:[(ORInFluxDBDelayCmd*)aCmd delayTime]];
        }
        else if(aCmd){
            NSMutableURLRequest* request = [aCmd requestFrom:self];
            NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
            NSURLSession*             session = [NSURLSession sessionWithConfiguration:config];
            NSURLSessionDataTask*      dbTask = [session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                if (!error) {
                    NSDictionary* result = [NSJSONSerialization JSONObjectWithData: data
                                                                           options: kNilOptions
                                                                             error: &error];
                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
                    [aCmd logResult:result code:(int)[httpResponse statusCode] delegate:self];
                }
            }];
            
            [dbTask resume]; //task is created in paused state, so start it
            
            totalSent += [aCmd requestSize];
        }
        [NSThread sleepForTimeInterval:.01];
        [pool release];
    }while(!canceled);
    [outerPool release];
}
@end

