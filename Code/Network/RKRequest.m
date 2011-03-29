//
//  RKRequest.m
//  RestKit
//
//  Created by Jeremy Ellison on 7/27/09.
//  Copyright 2009 Two Toasters. All rights reserved.
//

#import "RKRequest.h"
#import "RKRequestQueue.h"
#import "RKResponse.h"
#import "NSDictionary+RKRequestSerialization.h"
#import "RKNotifications.h"
#import "RKClient.h"
#import "../Support/Support.h"
#import "RKURL.h"
#import <UIKit/UIKit.h>

@implementation RKRequest

@synthesize URL = _URL, URLRequest = _URLRequest, delegate = _delegate, additionalHTTPHeaders = _additionalHTTPHeaders,
			params = _params, userData = _userData, username = _username, password = _password, method = _method,
            authenticationScheme = _authenticationScheme, backgroundPolicy = _backgroundPolicy, backgroundTaskIdentifier = _backgroundTaskIdentifier;

+ (RKRequest*)requestWithURL:(NSURL*)URL delegate:(id)delegate {
	return [[[RKRequest alloc] initWithURL:URL delegate:delegate] autorelease];
}

- (id)initWithURL:(NSURL*)URL {
    self = [self init];
	if (self) {
		_URL = [URL retain];
		_URLRequest = [[NSMutableURLRequest alloc] initWithURL:_URL];
		_connection = nil;
		_isLoading = NO;
		_isLoaded = NO;
        _backgroundPolicy = RKRequestBackgroundPolicyCancel;
	}
	return self;
}

- (id)initWithURL:(NSURL*)URL delegate:(id)delegate {
    self = [self initWithURL:URL];
	if (self) {
		_delegate = delegate;
	}
	return self;
}

- (id)init {
    self = [super init];
    if (self) {
        _backgroundTaskIdentifier = UIBackgroundTaskInvalid;
    }
    
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
	self.delegate = nil;
	[_connection cancel];
	[_connection release];
	_connection = nil;
	[_userData release];
	_userData = nil;
	[_URL release];
	_URL = nil;
	[_URLRequest release];
	_URLRequest = nil;
	[_params release];
	_params = nil;
	[_additionalHTTPHeaders release];
	_additionalHTTPHeaders = nil;
    [_authenticationScheme release];
	[_username release];
	_username = nil;
	[_password release];
	_password = nil;
	[super dealloc];
}

- (void)setRequestBody {
	if (_params && (_method != RKRequestMethodGET)) {
		// Prefer the use of a stream over a raw body
		if ([_params respondsToSelector:@selector(HTTPBodyStream)]) {
			[_URLRequest setHTTPBodyStream:[_params HTTPBodyStream]];
		} else {
			[_URLRequest setHTTPBody:[_params HTTPBody]];
		}
	}
}

- (void)addHeadersToRequest {
	NSString* header;
	for (header in _additionalHTTPHeaders) {
		[_URLRequest setValue:[_additionalHTTPHeaders valueForKey:header] forHTTPHeaderField:header];
	}

	if (_params != nil) {
		// Temporarily support older RKRequestSerializable implementations
		if ([_params respondsToSelector:@selector(HTTPHeaderValueForContentType)]) {
			[_URLRequest setValue:[_params HTTPHeaderValueForContentType] forHTTPHeaderField:@"Content-Type"];
		} else if ([_params respondsToSelector:@selector(ContentTypeHTTPHeader)]) {
			[_URLRequest setValue:[_params performSelector:@selector(ContentTypeHTTPHeader)] forHTTPHeaderField:@"Content-Type"];
		}
		if ([_params respondsToSelector:@selector(HTTPHeaderValueForContentLength)]) {
			[_URLRequest setValue:[NSString stringWithFormat:@"%d", [_params HTTPHeaderValueForContentLength]] forHTTPHeaderField:@"Content-Length"];
		}
	}
    
    if (_username != nil && [_authenticationScheme isEqualToString:(NSString*)kCFHTTPAuthenticationSchemeBasic]) {
        // Add authentication headers so we don't have to deal with an extra cycle for each message requiring basic auth.
        CFHTTPMessageRef dummyRequest = CFHTTPMessageCreateRequest(kCFAllocatorDefault, (CFStringRef)[self HTTPMethod], (CFURLRef)[self URL], kCFHTTPVersion1_1);
        CFHTTPMessageAddAuthentication(dummyRequest, nil, (CFStringRef)_username, (CFStringRef)_password, kCFHTTPAuthenticationSchemeBasic, FALSE);
        CFStringRef authorizationString = CFHTTPMessageCopyHeaderFieldValue(dummyRequest, CFSTR("Authorization"));

        [_URLRequest setValue:(NSString *)authorizationString forHTTPHeaderField:@"Authorization"];

        CFRelease(dummyRequest);
        CFRelease(authorizationString);
    }
    
	NSLog(@"Headers: %@", [_URLRequest allHTTPHeaderFields]);
}

// Setup the NSURLRequest. The request must be prepared right before dispatching
- (void)prepareURLRequest {
	[_URLRequest setHTTPMethod:[self HTTPMethod]];
	[self setRequestBody];
	[self addHeadersToRequest];
}

- (NSString*)HTTPMethod {
	switch (_method) {
		case RKRequestMethodGET:
			return @"GET";
			break;
		case RKRequestMethodPOST:
			return @"POST";
			break;
		case RKRequestMethodPUT:
			return @"PUT";
			break;
		case RKRequestMethodDELETE:
			return @"DELETE";
			break;
		default:
			return nil;
			break;
	}
}

- (void)send {
	[[RKRequestQueue sharedQueue] sendRequest:self];
}

- (void)fireAsynchronousRequest {
    [self prepareURLRequest];
    NSString* body = [[NSString alloc] initWithData:[_URLRequest HTTPBody] encoding:NSUTF8StringEncoding];
    NSLog(@"Sending %@ request to URL %@. HTTP Body: %@", [self HTTPMethod], [[self URL] absoluteString], body);
    [body release];
    [[NSNotificationCenter defaultCenter] postNotificationName:RKRequestSentNotification object:self userInfo:nil];
    
    _isLoading = YES;
    RKResponse* response = [[[RKResponse alloc] initWithRequest:self] autorelease];
    _connection = [[NSURLConnection connectionWithRequest:_URLRequest delegate:response] retain];
}

- (BOOL)shouldDispatchRequest {
    return [RKClient sharedClient] == nil || [[RKClient sharedClient] isNetworkAvailable];
}

- (void)sendAsynchronously {
	if ([self shouldDispatchRequest]) {
        // Background Request Policy support
        UIApplication* app = [UIApplication sharedApplication];
        if (self.backgroundPolicy == RKRequestBackgroundPolicyNone || 
            NO == [app respondsToSelector:@selector(beginBackgroundTaskWithExpirationHandler:)]) {
            // No support for background (iOS 3.x) or the policy is none -- just fire the request
            [self fireAsynchronousRequest];
        } else if (self.backgroundPolicy == RKRequestBackgroundPolicyCancel || self.backgroundPolicy == RKRequestBackgroundPolicyRequeue) {
            // For cancel or requeue behaviors, we watch for background transition notifications
            [[NSNotificationCenter defaultCenter] addObserver:self 
                                                     selector:@selector(appDidEnterBackgroundNotification:) 
                                                         name:UIApplicationDidEnterBackgroundNotification 
                                                       object:nil];
        } else if (self.backgroundPolicy == RKRequestBackgroundPolicyContinue) {
            // Fork a background task for continueing a long-running request
            _backgroundTaskIdentifier = [app beginBackgroundTaskWithExpirationHandler:^{
                NSLog(@"Background upload time expired, canceling request.");
                
                // TODO: Add a timeout case? or just cancel it?
                [self cancel];
            }];
            
            // Start the potentially long-running request
            [self fireAsynchronousRequest];
        }
	} else {
		NSString* errorMessage = [NSString stringWithFormat:@"The client is unable to contact the resource at %@", [[self URL] absoluteString]];
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
								  errorMessage, NSLocalizedDescriptionKey,
								  nil];
		NSError* error = [NSError errorWithDomain:RKRestKitErrorDomain code:RKRequestBaseURLOfflineError userInfo:userInfo];
		[self didFailLoadWithError:error];
	}
}

- (RKResponse*)sendSynchronously {
	NSURLResponse* URLResponse = nil;
	NSError* error = nil;
	NSData* payload = nil;
	RKResponse* response = nil;

	if ([self shouldDispatchRequest]) {
		[self prepareURLRequest];
		NSString* body = [[NSString alloc] initWithData:[_URLRequest HTTPBody] encoding:NSUTF8StringEncoding];
		NSLog(@"Sending synchronous %@ request to URL %@. HTTP Body: %@", [self HTTPMethod], [[self URL] absoluteString], body);
		[body release];
		NSDate* sentAt = [NSDate date];
		NSDictionary* userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[self HTTPMethod], @"HTTPMethod", [self URL], @"URL", sentAt, @"sentAt", nil];
		[[NSNotificationCenter defaultCenter] postNotificationName:kRKRequestSentNotification object:self userInfo:userInfo];

		_isLoading = YES;
		payload = [NSURLConnection sendSynchronousRequest:_URLRequest returningResponse:&URLResponse error:&error];
		response = [[[RKResponse alloc] initWithSynchronousRequest:self URLResponse:URLResponse body:payload error:error] autorelease];
        
        if (error) {
            [self didFailLoadWithError:error];
        } else {
            [self didFinishLoad:response];
        }
	} else {
		NSString* errorMessage = [NSString stringWithFormat:@"The client is unable to contact the resource at %@", [[self URL] absoluteString]];
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
								  errorMessage, NSLocalizedDescriptionKey,
								  nil];
		error = [NSError errorWithDomain:RKRestKitErrorDomain code:RKRequestBaseURLOfflineError userInfo:userInfo];
		[self didFailLoadWithError:error];

		// TODO: Is this needed here?  Or can we just return a nil response and everyone will be happy??
		response = [[[RKResponse alloc] initWithSynchronousRequest:self URLResponse:URLResponse body:payload error:error] autorelease];
	}

	return response;
}

- (void)cancelAndInformDelegate:(BOOL)informDelegate {
	[_connection cancel];
	[_connection release];
	_connection = nil;
	_isLoading = NO;
    
    if (informDelegate && [_delegate respondsToSelector:@selector(requestDidCancelLoad:)]) {
        [_delegate requestDidCancelLoad:self];
    }
}

- (void)cancel {
    [self cancelAndInformDelegate:YES];
}

- (void)didFailLoadWithError:(NSError*)error {
	_isLoading = NO;

	if ([_delegate respondsToSelector:@selector(request:didFailLoadWithError:)]) {
		[_delegate request:self didFailLoadWithError:error];
	}

	NSDate* receivedAt = [NSDate date];
	NSDictionary* userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[self HTTPMethod], @"HTTPMethod",
							  [self URL], @"URL", receivedAt, @"receivedAt", error, @"error", nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:kRKRequestFailedWithErrorNotification object:self userInfo:userInfo];
}

- (void)didFinishLoad:(RKResponse*)response {
	_isLoading = NO;
	_isLoaded = YES;

	if ([_delegate respondsToSelector:@selector(request:didLoadResponse:)]) {
		[_delegate request:self didLoadResponse:response];
	}

	NSDate* receivedAt = [NSDate date];
	NSDictionary* userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[self HTTPMethod], @"HTTPMethod", [self URL], @"URL", receivedAt, @"receivedAt", nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:kRKResponseReceivedNotification object:response userInfo:userInfo];

	if ([response isServiceUnavailable] && [[RKClient sharedClient] serviceUnavailableAlertEnabled]) {
		UIAlertView* alertView = [[UIAlertView alloc] initWithTitle:[[RKClient sharedClient] serviceUnavailableAlertTitle]
															message:[[RKClient sharedClient] serviceUnavailableAlertMessage]
														   delegate:nil
												  cancelButtonTitle:NSLocalizedString(@"OK", nil)
												  otherButtonTitles:nil];
		[alertView show];
		[alertView release];

	}
}

- (BOOL)isGET {
	return _method == RKRequestMethodGET;
}

- (BOOL)isPOST {
	return _method == RKRequestMethodPOST;
}

- (BOOL)isPUT {
	return _method == RKRequestMethodPUT;
}

- (BOOL)isDELETE {
	return _method == RKRequestMethodDELETE;
}

- (BOOL)isLoading {
	return _isLoading;
}

- (BOOL)isLoaded {
	return _isLoaded;
}

- (NSString*)resourcePath {
	NSString* resourcePath = nil;
	if ([self.URL isKindOfClass:[RKURL class]]) {
		RKURL* url = (RKURL*)self.URL;
		resourcePath = url.resourcePath;
	}
	return resourcePath;
}

- (BOOL)wasSentToResourcePath:(NSString*)resourcePath {
	return [[self resourcePath] isEqualToString:resourcePath];
}

- (void)appDidEnterBackgroundNotification:(NSNotification*)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    if (self.backgroundPolicy == RKRequestBackgroundPolicyCancel) {
        [self cancel];
    } else if (self.backgroundPolicy == RKRequestBackgroundPolicyRequeue) {
        // Cancel the existing request
        [self cancelAndInformDelegate:NO];
        [self send];
    }
}

@end
