/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "ABI35_0_0RCTBridge.h"
#import "ABI35_0_0RCTBridge+Private.h"

#import <objc/runtime.h>

#import "ABI35_0_0RCTConvert.h"
#import "ABI35_0_0RCTEventDispatcher.h"
#if ABI35_0_0RCT_ENABLE_INSPECTOR
#import "ABI35_0_0RCTInspectorDevServerHelper.h"
#endif
#import "ABI35_0_0RCTLog.h"
#import "ABI35_0_0RCTModuleData.h"
#import "ABI35_0_0RCTPerformanceLogger.h"
#import "ABI35_0_0RCTProfile.h"
#import "ABI35_0_0RCTReloadCommand.h"
#import "ABI35_0_0RCTUtils.h"

NSString *const ABI35_0_0RCTJavaScriptWillStartLoadingNotification = @"ABI35_0_0RCTJavaScriptWillStartLoadingNotification";
NSString *const ABI35_0_0RCTJavaScriptWillStartExecutingNotification = @"ABI35_0_0RCTJavaScriptWillStartExecutingNotification";
NSString *const ABI35_0_0RCTJavaScriptDidLoadNotification = @"ABI35_0_0RCTJavaScriptDidLoadNotification";
NSString *const ABI35_0_0RCTJavaScriptDidFailToLoadNotification = @"ABI35_0_0RCTJavaScriptDidFailToLoadNotification";
NSString *const ABI35_0_0RCTDidInitializeModuleNotification = @"ABI35_0_0RCTDidInitializeModuleNotification";
NSString *const ABI35_0_0RCTBridgeWillReloadNotification = @"ABI35_0_0RCTBridgeWillReloadNotification";
NSString *const ABI35_0_0RCTBridgeWillDownloadScriptNotification = @"ABI35_0_0RCTBridgeWillDownloadScriptNotification";
NSString *const ABI35_0_0RCTBridgeDidDownloadScriptNotification = @"ABI35_0_0RCTBridgeDidDownloadScriptNotification";
NSString *const ABI35_0_0RCTBridgeDidDownloadScriptNotificationSourceKey = @"source";
NSString *const ABI35_0_0RCTBridgeDidDownloadScriptNotificationBridgeDescriptionKey = @"bridgeDescription";

static NSMutableArray<Class> *ABI35_0_0RCTModuleClasses;
static dispatch_queue_t ABI35_0_0RCTModuleClassesSyncQueue;
NSArray<Class> *ABI35_0_0RCTGetModuleClasses(void)
{
  __block NSArray<Class> *result;
  dispatch_sync(ABI35_0_0RCTModuleClassesSyncQueue, ^{
    result = [ABI35_0_0RCTModuleClasses copy];
  });
  return result;
}

/**
 * Register the given class as a bridge module. All modules must be registered
 * prior to the first bridge initialization.
 */
void ABI35_0_0RCTRegisterModule(Class);
void ABI35_0_0RCTRegisterModule(Class moduleClass)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    ABI35_0_0RCTModuleClasses = [NSMutableArray new];
    ABI35_0_0RCTModuleClassesSyncQueue = dispatch_queue_create("com.facebook.ReactABI35_0_0.ModuleClassesSyncQueue", DISPATCH_QUEUE_CONCURRENT);
  });

  ABI35_0_0RCTAssert([moduleClass conformsToProtocol:@protocol(ABI35_0_0RCTBridgeModule)],
            @"%@ does not conform to the ABI35_0_0RCTBridgeModule protocol",
            moduleClass);

  // Register module
  dispatch_barrier_async(ABI35_0_0RCTModuleClassesSyncQueue, ^{
    [ABI35_0_0RCTModuleClasses addObject:moduleClass];
  });
}

/**
 * This function returns the module name for a given class.
 */
NSString *ABI35_0_0RCTBridgeModuleNameForClass(Class cls)
{
#if ABI35_0_0RCT_DEBUG
  ABI35_0_0RCTAssert([cls conformsToProtocol:@protocol(ABI35_0_0RCTBridgeModule)],
            @"Bridge module `%@` does not conform to ABI35_0_0RCTBridgeModule", cls);
#endif

  NSString *name = [cls moduleName];
  if (name.length == 0) {
    name = NSStringFromClass(cls);
  }

  return ABI35_0_0RCTDropReactABI35_0_0Prefixes(ABI35_0_0EX_REMOVE_VERSION(name));
}

static BOOL turboModuleEnabled = NO;
BOOL ABI35_0_0RCTTurboModuleEnabled(void)
{
  return turboModuleEnabled;
}

void ABI35_0_0RCTEnableTurboModule(BOOL enabled) {
  turboModuleEnabled = enabled;
}

#if ABI35_0_0RCT_DEBUG
void ABI35_0_0RCTVerifyAllModulesExported(NSArray *extraModules)
{
  // Check for unexported modules
  unsigned int classCount;
  Class *classes = objc_copyClassList(&classCount);

  NSMutableSet *moduleClasses = [NSMutableSet new];
  [moduleClasses addObjectsFromArray:ABI35_0_0RCTGetModuleClasses()];
  [moduleClasses addObjectsFromArray:[extraModules valueForKeyPath:@"class"]];

  for (unsigned int i = 0; i < classCount; i++) {
    Class cls = classes[i];
    if (strncmp(class_getName(cls), "ABI35_0_0RCTCxxModule", strlen("ABI35_0_0RCTCxxModule")) == 0) {
      continue;
    }
    Class superclass = cls;
    while (superclass) {
      if (class_conformsToProtocol(superclass, @protocol(ABI35_0_0RCTBridgeModule))) {
        if ([moduleClasses containsObject:cls]) {
          break;
        }

        // Verify it's not a super-class of one of our moduleClasses
        BOOL isModuleSuperClass = NO;
        for (Class moduleClass in moduleClasses) {
          if ([moduleClass isSubclassOfClass:cls]) {
            isModuleSuperClass = YES;
            break;
          }
        }
        if (isModuleSuperClass) {
          break;
        }

        // Note: Some modules may be lazily loaded and not exported up front, so this message is no longer a warning.
        ABI35_0_0RCTLogInfo(@"Class %@ was not exported. Did you forget to use ABI35_0_0RCT_EXPORT_MODULE()?", cls);
        break;
      }
      superclass = class_getSuperclass(superclass);
    }
  }

  free(classes);
}
#endif

@interface ABI35_0_0RCTBridge () <ABI35_0_0RCTReloadListener>
@end

@implementation ABI35_0_0RCTBridge
{
  NSURL *_delegateBundleURL;
}

dispatch_queue_t ABI35_0_0RCTJSThread;

+ (void)initialize
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{

    // Set up JS thread
    ABI35_0_0RCTJSThread = (id)kCFNull;
  });
}

static ABI35_0_0RCTBridge *ABI35_0_0RCTCurrentBridgeInstance = nil;

/**
 * The last current active bridge instance. This is set automatically whenever
 * the bridge is accessed. It can be useful for static functions or singletons
 * that need to access the bridge for purposes such as logging, but should not
 * be relied upon to return any particular instance, due to race conditions.
 */
+ (instancetype)currentBridge
{
  return ABI35_0_0RCTCurrentBridgeInstance;
}

+ (void)setCurrentBridge:(ABI35_0_0RCTBridge *)currentBridge
{
  ABI35_0_0RCTCurrentBridgeInstance = currentBridge;
}

- (instancetype)initWithDelegate:(id<ABI35_0_0RCTBridgeDelegate>)delegate
                   launchOptions:(NSDictionary *)launchOptions
{
  return [self initWithDelegate:delegate
                      bundleURL:nil
                 moduleProvider:nil
                  launchOptions:launchOptions];
}

- (instancetype)initWithBundleURL:(NSURL *)bundleURL
                   moduleProvider:(ABI35_0_0RCTBridgeModuleListProvider)block
                    launchOptions:(NSDictionary *)launchOptions
{
  return [self initWithDelegate:nil
                      bundleURL:bundleURL
                 moduleProvider:block
                  launchOptions:launchOptions];
}

- (instancetype)initWithDelegate:(id<ABI35_0_0RCTBridgeDelegate>)delegate
                       bundleURL:(NSURL *)bundleURL
                  moduleProvider:(ABI35_0_0RCTBridgeModuleListProvider)block
                   launchOptions:(NSDictionary *)launchOptions
{
  if (self = [super init]) {
    _delegate = delegate;
    _bundleURL = bundleURL;
    _moduleProvider = block;
    _launchOptions = [launchOptions copy];

    [self setUp];
  }
  return self;
}

ABI35_0_0RCT_NOT_IMPLEMENTED(- (instancetype)init)

- (void)dealloc
{
  /**
   * This runs only on the main thread, but crashes the subclass
   * ABI35_0_0RCTAssertMainQueue();
   */
  [self invalidate];
}

- (void)setABI35_0_0RCTTurboModuleLookupDelegate:(id<ABI35_0_0RCTTurboModuleLookupDelegate>)turboModuleLookupDelegate
{
  [self.batchedBridge setABI35_0_0RCTTurboModuleLookupDelegate:turboModuleLookupDelegate];
}

- (void)didReceiveReloadCommand
{
  [self reload];
}

- (NSArray<Class> *)moduleClasses
{
  return self.batchedBridge.moduleClasses;
}

- (id)moduleForName:(NSString *)moduleName
{
  return [self.batchedBridge moduleForName:moduleName];
}

- (id)moduleForName:(NSString *)moduleName lazilyLoadIfNecessary:(BOOL)lazilyLoad
{
  return [self.batchedBridge moduleForName:moduleName lazilyLoadIfNecessary:lazilyLoad];
}

- (id)moduleForClass:(Class)moduleClass
{
  id module = [self.batchedBridge moduleForClass:moduleClass];
  if (!module) {
    module = [self moduleForName:ABI35_0_0RCTBridgeModuleNameForClass(moduleClass)];
  }
  return module;
}

- (NSArray *)modulesConformingToProtocol:(Protocol *)protocol
{
  NSMutableArray *modules = [NSMutableArray new];
  for (Class moduleClass in [self.moduleClasses copy]) {
    if ([moduleClass conformsToProtocol:protocol]) {
      id module = [self moduleForClass:moduleClass];
      if (module) {
        [modules addObject:module];
      }
    }
  }
  return [modules copy];
}

- (BOOL)moduleIsInitialized:(Class)moduleClass
{
  return [self.batchedBridge moduleIsInitialized:moduleClass];
}

- (void)reload
{
  #if ABI35_0_0RCT_ENABLE_INSPECTOR
  // Disable debugger to resume the JsVM & avoid thread locks while reloading
  [ABI35_0_0RCTInspectorDevServerHelper disableDebugger];
  #endif

  [[NSNotificationCenter defaultCenter] postNotificationName:ABI35_0_0RCTBridgeWillReloadNotification object:self];

  /**
   * Any thread
   */
  dispatch_async(dispatch_get_main_queue(), ^{
    // WARNING: Invalidation is async, so it may not finish before re-setting up the bridge,
    // causing some issues. TODO: revisit this post-Fabric/TurboModule.
    [self invalidate];
    // Reload is a special case, do not preserve launchOptions and treat reload as a fresh start
    self->_launchOptions = nil;
    [self setUp];
  });
}

- (void)requestReload
{
  [self reload];
}

- (Class)bridgeClass
{
  return [ABI35_0_0RCTCxxBridge class];
}

- (void)setUp
{
  ABI35_0_0RCT_PROFILE_BEGIN_EVENT(0, @"-[ABI35_0_0RCTBridge setUp]", nil);

  _performanceLogger = [ABI35_0_0RCTPerformanceLogger new];
  [_performanceLogger markStartForTag:ABI35_0_0RCTPLBridgeStartup];
  [_performanceLogger markStartForTag:ABI35_0_0RCTPLTTI];

  Class bridgeClass = self.bridgeClass;

  #if ABI35_0_0RCT_DEV
  ABI35_0_0RCTExecuteOnMainQueue(^{
    ABI35_0_0RCTRegisterReloadCommandListener(self);
  });
  #endif

  // Only update bundleURL from delegate if delegate bundleURL has changed
  NSURL *previousDelegateURL = _delegateBundleURL;
  _delegateBundleURL = [self.delegate sourceURLForBridge:self];
  if (_delegateBundleURL && ![_delegateBundleURL isEqual:previousDelegateURL]) {
    _bundleURL = _delegateBundleURL;
  }

  // Sanitize the bundle URL
  _bundleURL = [ABI35_0_0RCTConvert NSURL:_bundleURL.absoluteString];

  self.batchedBridge = [[bridgeClass alloc] initWithParentBridge:self];
  [self.batchedBridge start];

  ABI35_0_0RCT_PROFILE_END_EVENT(ABI35_0_0RCTProfileTagAlways, @"");
}

- (BOOL)isLoading
{
  return self.batchedBridge.loading;
}

- (BOOL)isValid
{
  return self.batchedBridge.valid;
}

- (BOOL)isBatchActive
{
  return [_batchedBridge isBatchActive];
}

- (void)invalidate
{
  ABI35_0_0RCTBridge *batchedBridge = self.batchedBridge;
  self.batchedBridge = nil;

  if (batchedBridge) {
    ABI35_0_0RCTExecuteOnMainQueue(^{
      [batchedBridge invalidate];
    });
  }
}

- (void)updateModuleWithInstance:(id<ABI35_0_0RCTBridgeModule>)instance
{
  [self.batchedBridge updateModuleWithInstance:instance];
}

- (void)registerAdditionalModuleClasses:(NSArray<Class> *)modules
{
  [self.batchedBridge registerAdditionalModuleClasses:modules];
}

- (void)enqueueJSCall:(NSString *)moduleDotMethod args:(NSArray *)args
{
  NSArray<NSString *> *ids = [moduleDotMethod componentsSeparatedByString:@"."];
  NSString *module = ids[0];
  NSString *method = ids[1];
  [self enqueueJSCall:module method:method args:args completion:NULL];
}

- (void)enqueueJSCall:(NSString *)module method:(NSString *)method args:(NSArray *)args completion:(dispatch_block_t)completion
{
  [self.batchedBridge enqueueJSCall:module method:method args:args completion:completion];
}

- (void)enqueueCallback:(NSNumber *)cbID args:(NSArray *)args
{
  [self.batchedBridge enqueueCallback:cbID args:args];
}

- (void)registerSegmentWithId:(NSUInteger)segmentId path:(NSString *)path
{
  [self.batchedBridge registerSegmentWithId:segmentId path:path];
}

@end
