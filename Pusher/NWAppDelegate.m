//
//  NWAppDelegate.m
//  Pusher
//
//  Created by Leo on 9/9/12.
//  Copyright (c) 2012 noodlewerk. All rights reserved.
//

#import "NWAppDelegate.h"
#import "NWPusher.h"
#import "NWSecTools.h"


@implementation NWAppDelegate {
    IBOutlet NSPopUpButton *certificatePopup;
    IBOutlet NSComboBox *tokenCombo;
    IBOutlet NSTextView *payloadField;
    IBOutlet NSTextField *countField;
    IBOutlet NSTextField *infoField;
    IBOutlet NSButton *pushButton;
    
    NWPusher *pusher;
    NSDictionary *configuration;
    NSArray *certificates;
    NSUInteger index;
}


#pragma mark - Application delegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NWLog(@"Application did finish launching");
    NWLAddPrinter("NWPusher", NWPusherPrinter, 0);
    NWLPrintInfo();
    
    [self loadCertificatesFromKeychain];
    [self loadConfiguration];
    
    NSString *payload = [configuration valueForKey:@"payload"];
    payloadField.string = payload.length ? payload : @"";
    payloadField.font = [NSFont fontWithName:@"Courier" size:10];
    [self textDidChange:nil];
    index = 1;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NWLRemovePrinter("NWPusher");
    NWLog(@"Application will terminate");
    [pusher disconnect]; pusher = nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application
{
    return YES;
}


#pragma mark - UI events

- (IBAction)certificateSelected:(NSPopUpButton *)sender
{
    if (certificatePopup.indexOfSelectedItem) {
        id certificate = [certificates objectAtIndex:certificatePopup.indexOfSelectedItem - 1];
        [self selectCertificate:certificate];
    } else {
        [self selectCertificate:nil];
    }
}

- (void)textDidChange:(NSNotification *)notification
{
    NSUInteger length = payloadField.string.length;
    countField.stringValue = [NSString stringWithFormat:@"%lu", length];
    countField.textColor = length > 256 ? NSColor.redColor : NSColor.darkGrayColor;
}

- (IBAction)push:(NSButton *)sender
{
    if (pusher) {
        [self push];
    } else {
        NWLogWarn(@"No certificate selected");
    }
}


#pragma mark - Actions

- (void)loadConfiguration
{
    NSURL *defaultURL = [NSBundle.mainBundle URLForResource:@"configuration" withExtension:@"plist"];
    configuration = [NSDictionary dictionaryWithContentsOfURL:defaultURL];
    NSURL *libraryURL = [[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *configURL = [libraryURL URLByAppendingPathComponent:@"Pusher" isDirectory:YES];
    if (configURL) {
        NSError *error = nil;
        BOOL exists = [NSFileManager.defaultManager createDirectoryAtURL:configURL withIntermediateDirectories:YES attributes:nil error:&error];
        NWLogWarnIfError(error);
        if (exists) {
            NSURL *plistURL = [configURL URLByAppendingPathComponent:@"configuration.plist"];
            NSDictionary *config = [NSDictionary dictionaryWithContentsOfURL:plistURL];
            if ([config isKindOfClass:NSDictionary.class]) {
                NWLogInfo(@"Read configuration from ~/Library/Pusher/configuration.plist");
                configuration = config;
            } else if (![NSFileManager.defaultManager fileExistsAtPath:plistURL.path]){
                [configuration writeToURL:plistURL atomically:NO];
                NWLogInfo(@"Created default configuration in ~/Library/Pusher/configuration.plist");
            } else {
                NWLogInfo(@"Unable to read configuration from ~/Library/Pusher/configuration.plist");
            }
        }
    }
}

- (void)loadCertificatesFromKeychain
{
    NSArray *certs = nil;
    BOOL findCerts = [NWSecTools keychainCertificates:&certs];
    if (!findCerts || !certs.count) {
        NWLogWarn(@"No push certificates in keychain.");
    }
    certs = [certs sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        BOOL adev = [NWSecTools isDevelopmentCertificate:(__bridge SecCertificateRef)(a)];
        BOOL bdev = [NWSecTools isDevelopmentCertificate:(__bridge SecCertificateRef)(b)];
        if (adev != bdev) {
            return adev ? NSOrderedAscending : NSOrderedDescending;
        }
        NSString *aname = [NWSecTools identifierForCertificate:(__bridge SecCertificateRef)(a)];
        NSString *bname = [NWSecTools identifierForCertificate:(__bridge SecCertificateRef)(b)];
        return [aname compare:bname];
    }];
    certificates = certs;
    
    [certificatePopup removeAllItems];
    [certificatePopup addItemWithTitle:@"Select Push Certificate"];
    for (id c in certificates) {
        BOOL development = [NWSecTools isDevelopmentCertificate:(__bridge SecCertificateRef)(c)];
        NSString *name = [NWSecTools identifierForCertificate:(__bridge SecCertificateRef)(c)];
        [certificatePopup addItemWithTitle:[NSString stringWithFormat:@"%@ (%@)", name, development ? @"development" : @"production"]];
    }
}

- (NSArray *)tokensForCertificate:(id)certificate
{
    NSMutableArray *result = [[NSMutableArray alloc] init];
    BOOL development = [NWSecTools isDevelopmentCertificate:(__bridge SecCertificateRef)certificate];
    NSString *identifier = [NWSecTools identifierForCertificate:(__bridge SecCertificateRef)certificate];
    for (NSDictionary *dict in [configuration valueForKey:@"tokens"]) {
        NSArray *identifiers = [dict valueForKey:@"identifiers"];
        BOOL match = !identifiers;
        for (NSString *i in identifiers) {
            if ([i isEqualToString:identifier]) {
                match = YES;
                break;
            }
        }
        if (match) {
            NSArray *tokens = development ? [dict valueForKey:@"development"] : [dict valueForKey:@"production"];
            if (tokens.count) {
                [result addObjectsFromArray:tokens];
            }
        }
    }
    return result;
}

- (void)selectCertificate:(id)certificate
{
    if (pusher) {
        [pusher disconnect]; pusher = nil;
        pushButton.enabled = NO;
        NWLogInfo(@"Disconnected from APN");
    }
    
    NSArray *tokens = [self tokensForCertificate:certificate];
    [tokenCombo removeAllItems];
    tokenCombo.stringValue = @"";
    [tokenCombo addItemsWithObjectValues:tokens];
    
    if (certificate) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NWPusher *p = [[NWPusher alloc] init];
            BOOL sandbox = [NWSecTools isDevelopmentCertificate:(__bridge SecCertificateRef)(certificate)];
            BOOL connected = [p connectWithCertificateRef:(__bridge SecCertificateRef)(certificate) sandbox:sandbox];
            if (connected) {
                NWLogInfo(@"Connected established to APN%@", sandbox ? @" (sandbox)" : @"");
                pusher = p;
                pushButton.enabled = YES;
            } else {
                [p disconnect];
                [self deselectCombo];
            }
        });
    }
}

- (void)push
{
    NSString *payload = payloadField.string;
    NSString *token = tokenCombo.stringValue;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger i = index++;
        NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:86400];
        BOOL pushed = [pusher pushPayloadString:payload token:token identifier:i expires:expires];
        if (pushed) {
            NWLogInfo(@"Pushing payload #%i..", (int)i);
            dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC);
            dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                NSUInteger identifier = 0;
                NSString *reason = nil;
                BOOL fetched = [pusher fetchFailedIdentifier:&identifier reason:&reason];
                if (fetched) {
                    if (!reason.length) {
                        NWLogInfo(@"Payload #%i has been pushed", (int)i);
                    } else {
                        NWLogWarn(@"Payload #%i could not be pushed: %@", (int)identifier, reason);
                    }
                }
            });
        }
    });
}

- (void)deselectCombo
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [certificatePopup selectItemAtIndex:0];
    });
}


#pragma mark - NWLogging

- (void)log:(NSString *)message warning:(BOOL)warning
{
    dispatch_async(dispatch_get_main_queue(), ^{
        infoField.textColor = warning ? NSColor.redColor : NSColor.blackColor;
        infoField.stringValue = message;
    });
}

static void NWPusherPrinter(NWLContext context, CFStringRef message, void *info) {
    BOOL warning = strncmp(context.tag, "warn", 5) == 0;
    NWAppDelegate *delegate = NSApplication.sharedApplication.delegate;
    [delegate log:(__bridge NSString *)(message) warning:warning];
}

@end