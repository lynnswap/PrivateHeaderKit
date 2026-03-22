#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@interface PHRuntimeObjCPropertySnapshot : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *attributesString;
@property (nonatomic, readonly, getter=isClassProperty) BOOL classProperty;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface PHRuntimeObjCMethodSnapshot : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *typeEncoding;
@property (nonatomic, readonly, getter=isClassMethod) BOOL classMethod;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface PHRuntimeObjCIvarSnapshot : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *typeEncoding;
@property (nonatomic, readonly) ptrdiff_t offset;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface PHRuntimeObjCProtocolSnapshot : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCProtocolSnapshot *> *protocols;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCPropertySnapshot *> *classProperties;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCPropertySnapshot *> *properties;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCMethodSnapshot *> *classMethods;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCMethodSnapshot *> *methods;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCPropertySnapshot *> *optionalClassProperties;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCPropertySnapshot *> *optionalProperties;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCMethodSnapshot *> *optionalClassMethods;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCMethodSnapshot *> *optionalMethods;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface PHRuntimeObjCClassSnapshot : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) int32_t version;
@property (nonatomic, readonly, copy, nullable) NSString *imageName;
@property (nonatomic, readonly) NSUInteger instanceSize;
@property (nonatomic, readonly, copy, nullable) NSString *superClassName;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCProtocolSnapshot *> *protocols;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCIvarSnapshot *> *ivars;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCPropertySnapshot *> *classProperties;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCPropertySnapshot *> *properties;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCMethodSnapshot *> *classMethods;
@property (nonatomic, readonly, copy) NSArray<PHRuntimeObjCMethodSnapshot *> *methods;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface PHRuntimeObjCInspector : NSObject
+ (nullable PHRuntimeObjCClassSnapshot *)snapshotForClass:(Class)cls
                                             failedStage:(NSString * _Nullable * _Nullable)failedStage;
@end

NS_ASSUME_NONNULL_END
