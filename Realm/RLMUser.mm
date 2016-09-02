////////////////////////////////////////////////////////////////////////////
//
// Copyright 2016 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMUser_Private.hpp"

#import "RLMAuthResponseModel.h"
#import "RLMNetworkClient.h"
#import "RLMSyncManager_Private.hpp"
#import "RLMSyncSession_Private.h"
#import "RLMSyncUtil_Private.h"
#import "RLMTokenModels.h"
#import "RLMUtil.hpp"

#import "sync_metadata.hpp"

using namespace realm;

@interface RLMUser ()

- (instancetype)initWithAuthServer:(nullable NSURL *)authServer NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readwrite) BOOL isValid;
@property (nonatomic, readwrite) RLMIdentity identity;
@property (nonatomic, readwrite) NSURL *authenticationServer;

@property (nonatomic) NSMutableDictionary<NSURL *, RLMSyncSession *> *sessionsStorage;

@property (nonatomic) RLMServerToken directAccessToken;

@end

@implementation RLMUser

#pragma mark - static API

+ (NSArray *)all {
    return [[RLMSyncManager sharedManager] _allUsers];
}

#pragma mark - API

- (instancetype)initWithAuthServer:(nullable NSURL *)authServer {
    if (self = [super init]) {
        self.isValid = NO;
        self.directAccessToken = nil;
        self.authenticationServer = authServer;
        self.sessionsStorage = [NSMutableDictionary dictionary];
        // NOTE: If we add support for anonymous users, we will need to register the user to the global user store
        // when the user is first created, versus when the user logs in.
        return self;
    }
    return nil;
}

+ (instancetype)userWithAccessToken:(RLMServerToken)accessToken identity:(nullable NSString *)identity {
    RLMUser *user = [[RLMUser alloc] initWithAuthServer:nil];
    user.directAccessToken = accessToken;
    user.isValid = YES;
    user.identity = identity ?: [[NSUUID UUID] UUIDString];

    // Note that we explicitly do NOT persist users with direct access tokens.
    return user;
}

+ (void)authenticateWithCredential:(RLMCredential *)credential
                           actions:(RLMAuthenticationActions)actions
                     authServerURL:(NSURL *)authServerURL
                      onCompletion:(RLMUserCompletionBlock)completion {
    [self authenticateWithCredential:credential
                             actions:actions
                       authServerURL:authServerURL
                             timeout:30
                        onCompletion:completion];
}

+ (void)authenticateWithCredential:(RLMCredential *)credential
                            actions:(RLMAuthenticationActions)actions
                     authServerURL:(NSURL *)authServerURL
                           timeout:(NSTimeInterval)timeout
                      onCompletion:(RLMUserCompletionBlock)completion {
    RLMUser *user = [[RLMUser alloc] initWithAuthServer:authServerURL];
    [RLMUser _performLogInForUser:user
                       credential:credential
                          actions:actions
                    authServerURL:authServerURL
                          timeout:timeout
                  completionBlock:completion];
}

- (void)logOut {
    if (self.isValid || !self.identity) {
        @throw RLMException(@"Cannot log out a user that is already logged out.");
    }
    self.isValid = NO;
    [[RLMSyncManager sharedManager] _deregisterUser:self];
    auto metadata = SyncUserMetadata([[RLMSyncManager sharedManager] _metadataManager],
                                     [self.identity UTF8String],
                                     false);
    metadata.mark_for_removal();
}

- (NSDictionary<NSURL *, RLMSyncSession *> *)sessions {
    return [self.sessionsStorage copy];
}


#pragma mark - Private API

- (void)_invalidate {
    self.isValid = NO;
}

- (void)_deregisterSessionWithRealmURL:(NSURL *)realmURL {
    [self.sessionsStorage removeObjectForKey:realmURL];
}
    
- (instancetype)initWithMetadata:(SyncUserMetadata)metadata {
    NSURL *url = nil;
    if (metadata.server_url()) {
        url = [NSURL URLWithString:@(metadata.server_url()->c_str())];
    }
    self = [self initWithAuthServer:url];
    self.identity = @(metadata.identity().c_str());
    if (auto user_token = metadata.user_token()) {
        // FIXME: Once the new auth system is enabled, rename "refreshToken" to "userToken" to reflect its new role.
        self.refreshToken = @(user_token->c_str());
        self.isValid = YES;
    } else {
        // For now, throw an exception. In the future we may want to allow for "anonymous" style users.
        @throw RLMException(@"Invalid persisted user: there must be a valid access token.");
    }
    return self;
}

- (void)_updatePersistedMetadata {
    if (!self.refreshToken) {
        // For now, throw an exception. In the future we may want to allow for "anonymous" style users.
        @throw RLMException(@"Invalid persisted user: there must be a valid access token.");
    }

    NSURL *authServer = self.authenticationServer;
    NSString *refreshToken = self.refreshToken;
    auto server = authServer ? util::Optional<std::string>([[authServer absoluteString] UTF8String]) : none;
    auto token = refreshToken ? util::Optional<std::string>([refreshToken UTF8String]) : none;
    auto metadata = SyncUserMetadata([[RLMSyncManager sharedManager] _metadataManager], [self.identity UTF8String]);
    metadata.set_state(server, token);
}

+ (void)_performLogInForUser:(RLMUser *)user
                  credential:(RLMCredential *)credential
                     actions:(RLMAuthenticationActions)actions
               authServerURL:(NSURL *)authServerURL
                     timeout:(NSTimeInterval)timeout
             completionBlock:(RLMUserCompletionBlock)completion {
    // Wrap the completion block.
    RLMUserCompletionBlock theBlock = ^(RLMUser *user, NSError *error){
        if (!completion) { return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(user, error);
        });
    };

    // Prepare login network request
    NSMutableDictionary *json = [@{
                                   kRLMSyncProviderKey: credential.provider,
                                   kRLMSyncDataKey: credential.token,
                                   kRLMSyncAppIDKey: [RLMSyncManager sharedManager].appID,
                                   } mutableCopy];
    NSMutableDictionary *info = [(credential.userInfo ?: @{}) mutableCopy];

    // FIXME: handle the 'actions' flag for the general case (not just username/password)
    if (credential.provider == RLMIdentityProviderUsernamePassword
        && (actions & RLMAuthenticationActionsCreateAccount)) {
        info[kRLMSyncRegisterKey] = @(YES);
    }

    if ([info count] > 0) {
        // Munge user info into the JSON request.
        json[@"user_info"] = info;
    }

    RLMServerCompletionBlock handler = ^(NSError *error, NSDictionary *json) {
        if (json && !error) {
            RLMAuthResponseModel *model = [[RLMAuthResponseModel alloc] initWithDictionary:json
                                                                        requireAccessToken:NO
                                                                       requireRefreshToken:YES];
            if (!model) {
                // Malformed JSON
                error = [NSError errorWithDomain:RLMSyncErrorDomain
                                            code:RLMSyncErrorBadResponse
                                        userInfo:@{kRLMSyncErrorJSONKey: json}];
                theBlock(nil, error);
                return;
            } else {
                // Success: store the tokens.
                user.identity = model.refreshToken.tokenData.identity;
                user.refreshToken = model.refreshToken.token;
                [[RLMSyncManager sharedManager] _registerUser:user];
                user.isValid = YES;
                [user _updatePersistedMetadata];
                [user _bindAllDeferredRealms];
                theBlock(user, nil);
            }
        } else {
            // Something else went wrong
            theBlock(nil, error);
        }
    };
    [RLMNetworkClient postRequestToEndpoint:RLMServerEndpointAuth
                                     server:authServerURL
                                       JSON:json
                                    timeout:timeout
                                 completion:handler];
}

// Upon successfully logging in, bind any Realm which was opened and registered to the user previously.
- (void)_bindAllDeferredRealms {
    NSAssert(self.isValid, @"Logic error: _bindAllDeferredRealms can't be called unless the User is logged in.");
    for (NSURL *key in self.sessionsStorage) {
        RLMSyncSession *session = self.sessionsStorage[key];
        RLMRealmBindingPackage *package = session.deferredBindingPackage;
        if (session.state == RLMSyncSessionStateUnbound && package) {
            [self _bindRealmWithLocalFileURL:package.fileURL realmURL:package.realmURL onCompletion:package.block];
        }
    }
}

// Immediately begin the handshake to get the resolved remote path and the access token.
- (void)_bindRealmWithLocalFileURL:(NSURL *)fileURL
                          realmURL:(NSURL *)realmURL
                      onCompletion:(RLMErrorReportingBlock)completion {
    RLMServerPath unresolvedPath = [realmURL path];
    NSDictionary *json = @{
                           kRLMSyncPathKey: unresolvedPath,
                           kRLMSyncProviderKey: @"realm",
                           kRLMSyncDataKey: self.refreshToken,
                           kRLMSyncAppIDKey: [RLMSyncManager sharedManager].appID,
                           };

    RLMServerCompletionBlock handler = ^(NSError *error, NSDictionary *json) {
        if (json && !error) {
            RLMAuthResponseModel *model = [[RLMAuthResponseModel alloc] initWithDictionary:json
                                                                        requireAccessToken:YES
                                                                       requireRefreshToken:NO];
            if (!model) {
                // Malformed JSON
                error = [NSError errorWithDomain:RLMSyncErrorDomain
                                            code:RLMSyncErrorBadResponse
                                        userInfo:@{kRLMSyncErrorJSONKey: json}];
                [[RLMSyncManager sharedManager] _fireError:error];
                return;
            } else {
                // Success
                // For now, assume just one access token.
                RLMTokenModel *tokenModel = model.accessToken;
                NSString *accessToken = tokenModel.token;

                // Register the Realm as being linked to this User.
                RLMServerPath resolvedPath = tokenModel.tokenData.path;
                RLMSyncSession *session = [self.sessionsStorage objectForKey:realmURL];
                session.resolvedPath = resolvedPath;
                NSAssert(session,
                         @"Could not get a sync session object for the path '%@', this is an error",
                         unresolvedPath);

                [session configureWithAccessToken:accessToken expiry:tokenModel.tokenData.expires user:self];

                // Bind the Realm
                NSURLComponents *urlBuffer = [NSURLComponents componentsWithURL:realmURL resolvingAgainstBaseURL:YES];
                urlBuffer.path = resolvedPath;
                NSURL *resolvedURL = [urlBuffer URL];
                if (!resolvedURL) {
                    @throw RLMException(@"Resolved path returned from the server was invalid (%@).", resolvedPath);
                }
                std::string resolved_realm_url = [[resolvedURL absoluteString] UTF8String];
                bool success = Realm::refresh_sync_access_token([accessToken UTF8String],
                                                                RLMStringDataWithNSString([fileURL path]),
                                                                resolved_realm_url);
                session.deferredBindingPackage = nil;
                if (success) {
                    [session setState:RLMSyncSessionStateActive];
                } else {
                    [session _invalidate];
                }
                if (completion) {
                    completion(success ? nil : [NSError errorWithDomain:RLMSyncErrorDomain
                                                                   code:RLMSyncErrorClientSessionError
                                                               userInfo:nil]);
                }
            }
        } else {
            // Something else went wrong
            NSError *syncError = [NSError errorWithDomain:RLMSyncErrorDomain
                                                     code:RLMSyncErrorBadResponse
                                                 userInfo:@{kRLMSyncUnderlyingErrorKey: error}];
            [[RLMSyncManager sharedManager] _fireError:syncError];
        }
    };
    [RLMNetworkClient postRequestToEndpoint:RLMServerEndpointAuth
                                     server:self.authenticationServer
                                       JSON:json
                                 completion:handler];
}

// A callback handler for a Realm, used to get an updated access token which can then be used to bind the Realm.
- (void)_registerRealmForBindingWithFileURL:(NSURL *)fileURL
                                   realmURL:(NSURL *)realmURL
                               onCompletion:(nullable RLMErrorReportingBlock)completion {
    if ([self.sessionsStorage objectForKey:realmURL]) {
        // The Realm at this particular path has already been registered to this user.
        return;
    }

    RLMSyncSession *session = [[RLMSyncSession alloc] initWithFileURL:fileURL realmURL:realmURL];
    self.sessionsStorage[realmURL] = session;

    if (self.directAccessToken) {
        // Special case for when the access token is provided by the host app.
        std::string realm_url = [[realmURL absoluteString] UTF8String];
        bool success = Realm::refresh_sync_access_token(std::string([self.directAccessToken UTF8String]),
                                                        RLMStringDataWithNSString([fileURL path]),
                                                        realm_url);
        [session configureWithAccessToken:self.directAccessToken
                                   expiry:[[NSDate distantFuture] timeIntervalSince1970]
                                     user:self];
        if (success) {
            [session setState:RLMSyncSessionStateActive];
        } else {
            [session _invalidate];
        }
        if (completion) {
            completion(success ? nil : [NSError errorWithDomain:RLMSyncErrorDomain
                                                           code:RLMSyncErrorClientSessionError
                                                       userInfo:nil]);
        }
        return;
    }

    if (!self.isValid) {
        // We will delay the path resolution/access token handshake until the user logs in
        session.deferredBindingPackage = [[RLMRealmBindingPackage alloc] initWithFileURL:fileURL
                                                                                realmURL:realmURL
                                                                                   block:completion];
    } else {
        // User is logged in, start the handshake immediately.
        [self _bindRealmWithLocalFileURL:fileURL realmURL:realmURL onCompletion:completion];
    }
}

#pragma mark - Temporary API

- (instancetype)initWithIdentity:(NSString *)identity
                    refreshToken:(RLMServerToken)refreshToken
                   authServerURL:(NSURL *)authServerURL {
    if (self = [self initWithAuthServer:authServerURL]) {
        self.refreshToken = refreshToken;
        self.identity = identity;
        self.isValid = YES;
        [[RLMSyncManager sharedManager] _registerUser:self];
    }
    return self;
}

@end
