#import "RNBoundary.h"

@implementation GeofenceEvent
- (id)initWithId:(NSString*)geofenceId forEvent:(NSString *)name {
    self = [super init];
    if (self) {
      self.geofenceId = geofenceId;
      self.name = name;
      self.date = [NSDate date];
    }

    return self;
}

- (BOOL)isEqual:(id)anObject
{
    return [self.geofenceId isEqual:((GeofenceEvent *)anObject).geofenceId];
}

- (NSUInteger)hash
{
    return self.geofenceId;
}
@end


@implementation RNBoundary

RCT_EXPORT_MODULE()

-(instancetype)init
{
    self = [super init];
    if (self) {
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.delegate = self;
        self.queuedEvents = [[NSMutableSet alloc] init];
        self.enteredSubRegions = [NSMutableDictionary new];

    }

    return self;
}

RCT_EXPORT_METHOD(add:(NSDictionary*)boundary addWithResolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
    if (CLLocationManager.authorizationStatus != kCLAuthorizationStatusAuthorizedAlways) {
        [self.locationManager requestAlwaysAuthorization];
    }

    if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedAlways) {
        NSString *id = boundary[@"id"];
        CLLocationCoordinate2D center = CLLocationCoordinate2DMake([boundary[@"lat"] doubleValue], [boundary[@"lng"] doubleValue]);
        CLCircularRegion *boundaryRegion = [[CLCircularRegion alloc]initWithCenter:center
                                                                    radius:[boundary[@"radius"] doubleValue]
                                                                identifier:id];
 
        [self.locationManager startMonitoringForRegion:boundaryRegion];
        if([boundaryRegion containsCoordinate:self.locationManager.location.coordinate]) {
            self.locationManager.activityType = CLActivityTypeFitness;
            self.locationManager.distanceFilter = 5;
            [self.locationManager startUpdatingLocation];
        }

        resolve(id);
    } else {
        reject(@"PERM", @"Access fine location is not permitted", [NSError errorWithDomain:@"boundary" code:200 userInfo:@{@"Error reason": @"Invalid permissions"}]);
    }
}

RCT_EXPORT_METHOD(remove:(NSString *)boundaryId removeWithResolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
    if ([self removeBoundary:boundaryId]) {
        resolve(boundaryId);
        [self.enteredSubRegions removeObjectForKey:boundaryId];
        if(![[self.enteredSubRegions allValues] containsObject:@YES]) {
            [self.locationManager stopUpdatingLocation];
        }
    } else {
        reject(@"@no_boundary", @"No boundary with the provided id was found", [NSError errorWithDomain:@"boundary" code:200 userInfo:@{@"Error reason": @"Invalid boundary ID"}]);
    }
}

RCT_EXPORT_METHOD(removeAll:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        [self removeAllBoundaries];
        [self.enteredSubRegions removeAllObjects];
        [self.locationManager stopUpdatingLocation];
    
    }
    @catch (NSError *ex) {
        reject(@"failed_remove_all", @"Failed to remove all boundaries", ex);
    }
    resolve(NULL);
}

- (void) removeAllBoundaries
{
    for(CLRegion *region in [self.locationManager monitoredRegions]) {
        [self.locationManager stopMonitoringForRegion:region];
    }
    [self.queuedEvents removeAllObjects];
}

- (bool) removeBoundary:(NSString *)boundaryId
{
    for(CLRegion *region in [self.locationManager monitoredRegions]){
        if ([region.identifier isEqualToString:boundaryId]) {
            [self.locationManager stopMonitoringForRegion:region];
            return true;
        }
    }
    return false;
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"onEnter", @"onExit", @"onLog"];
}

- (void)locationManager:(CLLocationManager *)manager didEnterRegion:(CLRegion *)region
{
    for (CLCircularRegion *enteredRegion in _locationManager.monitoredRegions.allObjects) {
        if ([enteredRegion.identifier isEqualToString:region.identifier]) {

            self.locationManager.activityType = CLActivityTypeFitness;
            self.locationManager.distanceFilter = 50;
            [self.locationManager startUpdatingLocation];

            break;
        }
    }
    
    NSLog(@"start monitoring for region : %@", region);

}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region
{
    if(![[self.enteredSubRegions allValues] containsObject:@YES]) {
        [_locationManager stopUpdatingLocation];
    }
    
    if([self.enteredSubRegions[region.identifier] isEqual:@YES]) {
        [self.enteredSubRegions removeObjectForKey:region.identifier];
                NSLog(@"didExit : %@", region.identifier);
                if (self.hasListeners) {
                  [self sendEventWithName:@"onExit" body:region.identifier];
                } else {
                  GeofenceEvent *event = [[GeofenceEvent alloc] initWithId:region.identifier forEvent:@"onExit" ];
                  [self.queuedEvents addObject:event];
                }
            }
}

-(void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *firstLocation = [locations firstObject];
    CGFloat const DESIRED_RADIUS = 100.0;
    [self sendEventWithName:@"onLog" body:@"Did Update Locations"];

    CLCircularRegion *circularRegion = [[CLCircularRegion alloc] initWithCenter:firstLocation.coordinate radius:DESIRED_RADIUS identifier:@"radiusCheck"];

    for (CLCircularRegion *enteredRegion in _locationManager.monitoredRegions.allObjects) {
        if ([circularRegion containsCoordinate:enteredRegion.center]) {
             NSString *log = [NSString stringWithFormat:@"You are within %@ of %@", @(DESIRED_RADIUS), enteredRegion.identifier];
            NSLog(log);
            [self sendEventWithName:@"onLog" body:log];
            if(![self.enteredSubRegions[enteredRegion.identifier] isEqual:@YES]) {
                [self.enteredSubRegions setValue:@YES forKey:enteredRegion.identifier];
                if (self.hasListeners) {
                  [self sendEventWithName:@"onEnter" body:enteredRegion.identifier];
                    [self sendEventWithName:@"onLog" body:[NSString stringWithFormat:@"ENTERED %@", enteredRegion.identifier]];

                } else {
                  GeofenceEvent *event = [[GeofenceEvent alloc] initWithId:enteredRegion.identifier forEvent:@"onEnter" ];
                  [self.queuedEvents addObject:event];
                }
            }
            break;
        } else if ([enteredRegion containsCoordinate:circularRegion.center]) {
            NSString *log = [NSString stringWithFormat:@"You are within the region, but not yet %@m from %@", @(DESIRED_RADIUS), enteredRegion.identifier];
            NSLog(log);
            [self sendEventWithName:@"onLog" body:log];

            if([self.enteredSubRegions[enteredRegion.identifier] isEqual:@YES]) {
                [self.enteredSubRegions removeObjectForKey:enteredRegion.identifier];
                NSLog(@"didExit : %@", enteredRegion.identifier);
                if (self.hasListeners) {
                  [self sendEventWithName:@"onExit" body:enteredRegion.identifier];
                    [self sendEventWithName:@"onLog" body:[NSString stringWithFormat:@"EXITED %@", enteredRegion.identifier]];

                } else {
                  GeofenceEvent *event = [[GeofenceEvent alloc] initWithId:enteredRegion.identifier forEvent:@"onExit" ];
                  [self.queuedEvents addObject:event];
                }
            }
        }
    }
}



- (void)startObserving {
    self.hasListeners = YES;
    if ([self.queuedEvents count] > 0) {
      for(GeofenceEvent *event in self.queuedEvents) {
        NSTimeInterval interval = [[NSDate date] timeIntervalSinceDate:[event date]];
        double minutesDiff = interval / 60.f;
        // if the app was not open
        // within 2 minutes of storing the event
        // we discard it
        if (minutesDiff < 2) {
          // dispatch after 1 second
          // as both events are not registered at the same time
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self sendEventWithName:[event name] body:[event geofenceId]];
          });
        }
      }
      [self.queuedEvents removeAllObjects];
    }
}

- (void)stopObserving {
    self.hasListeners = NO;
    [self.queuedEvents removeAllObjects];
}

+ (BOOL)requiresMainQueueSetup
{
  return YES;
}

@end
