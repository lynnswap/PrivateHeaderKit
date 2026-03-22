#import "HeaderDumpRuntimeObjC.h"

static NSString * const PHRuntimeStageName = @"name";
static NSString * const PHRuntimeStageImage = @"imageName";
static NSString * const PHRuntimeStageVersion = @"version";
static NSString * const PHRuntimeStageInstanceSize = @"instanceSize";
static NSString * const PHRuntimeStageSuperclass = @"superClassName";
static NSString * const PHRuntimeStageProtocols = @"protocols";
static NSString * const PHRuntimeStageIvars = @"ivars";
static NSString * const PHRuntimeStageClassProperties = @"classProperties";
static NSString * const PHRuntimeStageProperties = @"properties";
static NSString * const PHRuntimeStageClassMethods = @"classMethods";
static NSString * const PHRuntimeStageMethods = @"methods";
static NSString * const PHRuntimeStageOptionalClassProperties = @"optionalClassProperties";
static NSString * const PHRuntimeStageOptionalProperties = @"optionalProperties";
static NSString * const PHRuntimeStageOptionalClassMethods = @"optionalClassMethods";
static NSString * const PHRuntimeStageOptionalMethods = @"optionalMethods";

@interface PHRuntimeObjCPropertySnapshot ()
- (instancetype)initWithName:(NSString *)name
            attributesString:(NSString *)attributesString
               classProperty:(BOOL)classProperty;
@end

@implementation PHRuntimeObjCPropertySnapshot
- (instancetype)initWithName:(NSString *)name
            attributesString:(NSString *)attributesString
               classProperty:(BOOL)classProperty {
    self = [super init];
    if (self) {
        _name = [name copy];
        _attributesString = [attributesString copy];
        _classProperty = classProperty;
    }
    return self;
}
@end

@interface PHRuntimeObjCMethodSnapshot ()
- (instancetype)initWithName:(NSString *)name
                typeEncoding:(NSString *)typeEncoding
                 classMethod:(BOOL)classMethod;
@end

@implementation PHRuntimeObjCMethodSnapshot
- (instancetype)initWithName:(NSString *)name
                typeEncoding:(NSString *)typeEncoding
                 classMethod:(BOOL)classMethod {
    self = [super init];
    if (self) {
        _name = [name copy];
        _typeEncoding = [typeEncoding copy];
        _classMethod = classMethod;
    }
    return self;
}
@end

@interface PHRuntimeObjCIvarSnapshot ()
- (instancetype)initWithName:(NSString *)name
                typeEncoding:(NSString *)typeEncoding
                      offset:(ptrdiff_t)offset;
@end

@implementation PHRuntimeObjCIvarSnapshot
- (instancetype)initWithName:(NSString *)name
                typeEncoding:(NSString *)typeEncoding
                      offset:(ptrdiff_t)offset {
    self = [super init];
    if (self) {
        _name = [name copy];
        _typeEncoding = [typeEncoding copy];
        _offset = offset;
    }
    return self;
}
@end

@interface PHRuntimeObjCProtocolSnapshot ()
- (instancetype)initWithName:(NSString *)name
                   protocols:(NSArray<PHRuntimeObjCProtocolSnapshot *> *)protocols
             classProperties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)classProperties
                  properties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)properties
                classMethods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)classMethods
                     methods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)methods
      optionalClassProperties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)optionalClassProperties
           optionalProperties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)optionalProperties
         optionalClassMethods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)optionalClassMethods
              optionalMethods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)optionalMethods;
@end

@implementation PHRuntimeObjCProtocolSnapshot
- (instancetype)initWithName:(NSString *)name
                   protocols:(NSArray<PHRuntimeObjCProtocolSnapshot *> *)protocols
             classProperties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)classProperties
                  properties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)properties
                classMethods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)classMethods
                     methods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)methods
      optionalClassProperties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)optionalClassProperties
           optionalProperties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)optionalProperties
         optionalClassMethods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)optionalClassMethods
              optionalMethods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)optionalMethods {
    self = [super init];
    if (self) {
        _name = [name copy];
        _protocols = [protocols copy];
        _classProperties = [classProperties copy];
        _properties = [properties copy];
        _classMethods = [classMethods copy];
        _methods = [methods copy];
        _optionalClassProperties = [optionalClassProperties copy];
        _optionalProperties = [optionalProperties copy];
        _optionalClassMethods = [optionalClassMethods copy];
        _optionalMethods = [optionalMethods copy];
    }
    return self;
}
@end

@interface PHRuntimeObjCClassSnapshot ()
- (instancetype)initWithName:(NSString *)name
                     version:(int32_t)version
                   imageName:(NSString * _Nullable)imageName
                instanceSize:(NSUInteger)instanceSize
              superClassName:(NSString * _Nullable)superClassName
                   protocols:(NSArray<PHRuntimeObjCProtocolSnapshot *> *)protocols
                       ivars:(NSArray<PHRuntimeObjCIvarSnapshot *> *)ivars
             classProperties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)classProperties
                  properties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)properties
                classMethods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)classMethods
                     methods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)methods;
@end

@implementation PHRuntimeObjCClassSnapshot
- (instancetype)initWithName:(NSString *)name
                     version:(int32_t)version
                   imageName:(NSString * _Nullable)imageName
                instanceSize:(NSUInteger)instanceSize
              superClassName:(NSString * _Nullable)superClassName
                   protocols:(NSArray<PHRuntimeObjCProtocolSnapshot *> *)protocols
                       ivars:(NSArray<PHRuntimeObjCIvarSnapshot *> *)ivars
             classProperties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)classProperties
                  properties:(NSArray<PHRuntimeObjCPropertySnapshot *> *)properties
                classMethods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)classMethods
                     methods:(NSArray<PHRuntimeObjCMethodSnapshot *> *)methods {
    self = [super init];
    if (self) {
        _name = [name copy];
        _version = version;
        _imageName = [imageName copy];
        _instanceSize = instanceSize;
        _superClassName = [superClassName copy];
        _protocols = [protocols copy];
        _ivars = [ivars copy];
        _classProperties = [classProperties copy];
        _properties = [properties copy];
        _classMethods = [classMethods copy];
        _methods = [methods copy];
    }
    return self;
}
@end

static NSArray<PHRuntimeObjCProtocolSnapshot *> * _Nullable
PHRuntimeProtocolSnapshotsFromList(Protocol * __unsafe_unretained const _Nullable *start,
                                   unsigned int count,
                                   NSString * _Nullable * _Nullable failedStage);

static NSArray<PHRuntimeObjCPropertySnapshot *> * _Nullable
PHRuntimePropertySnapshotsForClass(Class cls, BOOL isInstance, NSString *stage, NSString * _Nullable * _Nullable failedStage) {
    Class target = cls;
    if (!isInstance) {
        @try {
            target = object_getClass((id)cls);
        } @catch (NSException *) {
            if (failedStage) { *failedStage = stage; }
            return nil;
        }
        if (target == Nil) {
            if (failedStage) { *failedStage = stage; }
            return nil;
        }
    }

    objc_property_t *start = NULL;
    unsigned int count = 0;
    @try {
        start = class_copyPropertyList(target, &count);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = stage; }
        return nil;
    }

    NSMutableArray<PHRuntimeObjCPropertySnapshot *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int idx = 0; idx < count; idx++) {
        const char *name = property_getName(start[idx]);
        const char *attributes = property_getAttributes(start[idx]);
        if (!name || !attributes) { continue; }
        NSString *nameString = [NSString stringWithUTF8String:name];
        NSString *attributesString = [NSString stringWithUTF8String:attributes];
        if (!nameString || !attributesString) { continue; }
        [result addObject:[[PHRuntimeObjCPropertySnapshot alloc] initWithName:nameString
                                                             attributesString:attributesString
                                                                classProperty:!isInstance]];
    }
    if (start) { free(start); }
    return result;
}

static NSArray<PHRuntimeObjCMethodSnapshot *> * _Nullable
PHRuntimeMethodSnapshotsForClass(Class cls, BOOL isInstance, NSString *stage, NSString * _Nullable * _Nullable failedStage) {
    Class target = cls;
    if (!isInstance) {
        @try {
            target = object_getClass((id)cls);
        } @catch (NSException *) {
            if (failedStage) { *failedStage = stage; }
            return nil;
        }
        if (target == Nil) {
            if (failedStage) { *failedStage = stage; }
            return nil;
        }
    }

    Method *start = NULL;
    unsigned int count = 0;
    @try {
        start = class_copyMethodList(target, &count);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = stage; }
        return nil;
    }

    NSMutableArray<PHRuntimeObjCMethodSnapshot *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int idx = 0; idx < count; idx++) {
        const char *typeEncoding = method_getTypeEncoding(start[idx]);
        SEL selector = method_getName(start[idx]);
        if (!typeEncoding || selector == NULL) { continue; }
        NSString *nameString = NSStringFromSelector(selector);
        NSString *typeString = [NSString stringWithUTF8String:typeEncoding];
        if (!nameString || !typeString) { continue; }
        [result addObject:[[PHRuntimeObjCMethodSnapshot alloc] initWithName:nameString
                                                               typeEncoding:typeString
                                                                classMethod:!isInstance]];
    }
    if (start) { free(start); }
    return result;
}

static NSArray<PHRuntimeObjCIvarSnapshot *> * _Nullable
PHRuntimeIvarSnapshotsForClass(Class cls, NSString * _Nullable * _Nullable failedStage) {
    Ivar *start = NULL;
    unsigned int count = 0;
    @try {
        start = class_copyIvarList(cls, &count);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageIvars; }
        return nil;
    }

    NSMutableArray<PHRuntimeObjCIvarSnapshot *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int idx = 0; idx < count; idx++) {
        const char *name = ivar_getName(start[idx]);
        const char *typeEncoding = ivar_getTypeEncoding(start[idx]);
        if (!name || !typeEncoding) { continue; }
        NSString *nameString = [NSString stringWithUTF8String:name];
        NSString *typeString = [NSString stringWithUTF8String:typeEncoding];
        if (!nameString || !typeString) { continue; }
        [result addObject:[[PHRuntimeObjCIvarSnapshot alloc] initWithName:nameString
                                                             typeEncoding:typeString
                                                                   offset:ivar_getOffset(start[idx])]];
    }
    if (start) { free(start); }
    return result;
}

static NSArray<PHRuntimeObjCMethodSnapshot *> * _Nullable
PHRuntimeMethodSnapshotsForProtocol(Protocol *protocol, BOOL isRequired, BOOL isInstance, NSString *stage, NSString * _Nullable * _Nullable failedStage) {
    struct objc_method_description *start = NULL;
    unsigned int count = 0;
    @try {
        start = protocol_copyMethodDescriptionList(protocol, isRequired, isInstance, &count);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = stage; }
        return nil;
    }

    NSMutableArray<PHRuntimeObjCMethodSnapshot *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int idx = 0; idx < count; idx++) {
        if (start[idx].name == NULL || start[idx].types == NULL) { continue; }
        NSString *nameString = NSStringFromSelector(start[idx].name);
        NSString *typeString = [NSString stringWithUTF8String:start[idx].types];
        if (!nameString || !typeString) { continue; }
        [result addObject:[[PHRuntimeObjCMethodSnapshot alloc] initWithName:nameString
                                                               typeEncoding:typeString
                                                                classMethod:!isInstance]];
    }
    if (start) { free(start); }
    return result;
}

static NSArray<PHRuntimeObjCPropertySnapshot *> * _Nullable
PHRuntimePropertySnapshotsForProtocol(Protocol *protocol, BOOL isRequired, BOOL isInstance, NSString *stage, NSString * _Nullable * _Nullable failedStage) {
    objc_property_t *start = NULL;
    unsigned int count = 0;
    @try {
        start = protocol_copyPropertyList2(protocol, &count, isRequired, isInstance);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = stage; }
        return nil;
    }

    NSMutableArray<PHRuntimeObjCPropertySnapshot *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int idx = 0; idx < count; idx++) {
        const char *name = property_getName(start[idx]);
        const char *attributes = property_getAttributes(start[idx]);
        if (!name || !attributes) { continue; }
        NSString *nameString = [NSString stringWithUTF8String:name];
        NSString *attributesString = [NSString stringWithUTF8String:attributes];
        if (!nameString || !attributesString) { continue; }
        [result addObject:[[PHRuntimeObjCPropertySnapshot alloc] initWithName:nameString
                                                             attributesString:attributesString
                                                                classProperty:!isInstance]];
    }
    if (start) { free(start); }
    return result;
}

static PHRuntimeObjCProtocolSnapshot * _Nullable
PHRuntimeProtocolSnapshot(Protocol *protocol, NSString * _Nullable * _Nullable failedStage) {
    NSString *name = nil;
    @try {
        const char *protocolName = protocol_getName(protocol);
        if (!protocolName) {
            if (failedStage) { *failedStage = PHRuntimeStageProtocols; }
            return nil;
        }
        name = [NSString stringWithUTF8String:protocolName];
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageProtocols; }
        return nil;
    }
    if (!name) {
        if (failedStage) { *failedStage = PHRuntimeStageProtocols; }
        return nil;
    }

    Protocol *__unsafe_unretained *protocolStart = NULL;
    unsigned int protocolCount = 0;
    @try {
        protocolStart = protocol_copyProtocolList(protocol, &protocolCount);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageProtocols; }
        return nil;
    }
    NSArray<PHRuntimeObjCProtocolSnapshot *> *protocols = PHRuntimeProtocolSnapshotsFromList(protocolStart, protocolCount, failedStage);
    if (protocolStart) { free(protocolStart); }
    if (!protocols && failedStage && *failedStage) { return nil; }

    NSArray<PHRuntimeObjCPropertySnapshot *> *classProperties = PHRuntimePropertySnapshotsForProtocol(protocol, YES, NO, PHRuntimeStageClassProperties, failedStage);
    if (!classProperties && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCPropertySnapshot *> *properties = PHRuntimePropertySnapshotsForProtocol(protocol, YES, YES, PHRuntimeStageProperties, failedStage);
    if (!properties && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCMethodSnapshot *> *classMethods = PHRuntimeMethodSnapshotsForProtocol(protocol, YES, NO, PHRuntimeStageClassMethods, failedStage);
    if (!classMethods && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCMethodSnapshot *> *methods = PHRuntimeMethodSnapshotsForProtocol(protocol, YES, YES, PHRuntimeStageMethods, failedStage);
    if (!methods && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCPropertySnapshot *> *optionalClassProperties = PHRuntimePropertySnapshotsForProtocol(protocol, NO, NO, PHRuntimeStageOptionalClassProperties, failedStage);
    if (!optionalClassProperties && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCPropertySnapshot *> *optionalProperties = PHRuntimePropertySnapshotsForProtocol(protocol, NO, YES, PHRuntimeStageOptionalProperties, failedStage);
    if (!optionalProperties && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCMethodSnapshot *> *optionalClassMethods = PHRuntimeMethodSnapshotsForProtocol(protocol, NO, NO, PHRuntimeStageOptionalClassMethods, failedStage);
    if (!optionalClassMethods && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCMethodSnapshot *> *optionalMethods = PHRuntimeMethodSnapshotsForProtocol(protocol, NO, YES, PHRuntimeStageOptionalMethods, failedStage);
    if (!optionalMethods && failedStage && *failedStage) { return nil; }

    return [[PHRuntimeObjCProtocolSnapshot alloc] initWithName:name
                                                     protocols:protocols ?: @[]
                                               classProperties:classProperties ?: @[]
                                                    properties:properties ?: @[]
                                                  classMethods:classMethods ?: @[]
                                                       methods:methods ?: @[]
                                        optionalClassProperties:optionalClassProperties ?: @[]
                                             optionalProperties:optionalProperties ?: @[]
                                           optionalClassMethods:optionalClassMethods ?: @[]
                                                optionalMethods:optionalMethods ?: @[]];
}

static NSArray<PHRuntimeObjCProtocolSnapshot *> * _Nullable
PHRuntimeProtocolSnapshotsFromList(Protocol * __unsafe_unretained const _Nullable *start,
                                   unsigned int count,
                                   NSString * _Nullable * _Nullable failedStage) {
    NSMutableArray<PHRuntimeObjCProtocolSnapshot *> *result = [NSMutableArray arrayWithCapacity:count];
    if (start == NULL || count == 0) { return result; }

    for (unsigned int idx = 0; idx < count; idx++) {
        Protocol *protocol = start[idx];
        if (!protocol) { continue; }
        PHRuntimeObjCProtocolSnapshot *snapshot = PHRuntimeProtocolSnapshot(protocol, failedStage);
        if (!snapshot && failedStage && *failedStage) {
            return nil;
        }
        if (snapshot) {
            [result addObject:snapshot];
        }
    }
    return result;
}

static NSArray<PHRuntimeObjCProtocolSnapshot *> * _Nullable
PHRuntimeProtocolSnapshotsForClass(Class cls, NSString * _Nullable * _Nullable failedStage) {
    Protocol *__unsafe_unretained *start = NULL;
    unsigned int count = 0;
    @try {
        start = class_copyProtocolList(cls, &count);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageProtocols; }
        return nil;
    }
    NSArray<PHRuntimeObjCProtocolSnapshot *> *result = PHRuntimeProtocolSnapshotsFromList(start, count, failedStage);
    if (start) { free(start); }
    return result;
}

@implementation PHRuntimeObjCInspector
+ (PHRuntimeObjCClassSnapshot *)snapshotForClass:(Class)cls
                                    failedStage:(NSString * _Nullable * _Nullable)failedStage {
    if (failedStage) { *failedStage = nil; }

    NSString *name = nil;
    @try {
        name = NSStringFromClass(cls);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageName; }
        return nil;
    }
    if (!name) {
        if (failedStage) { *failedStage = PHRuntimeStageName; }
        return nil;
    }

    NSString *imageName = nil;
    @try {
        const char *image = class_getImageName(cls);
        if (image) {
            imageName = [NSString stringWithUTF8String:image];
        }
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageImage; }
        return nil;
    }

    int32_t version = 0;
    @try {
        version = class_getVersion(cls);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageVersion; }
        return nil;
    }

    NSUInteger instanceSize = 0;
    @try {
        instanceSize = class_getInstanceSize(cls);
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageInstanceSize; }
        return nil;
    }

    NSString *superClassName = nil;
    @try {
        Class superClass = class_getSuperclass(cls);
        if (superClass) {
            superClassName = NSStringFromClass(superClass);
        }
    } @catch (NSException *) {
        if (failedStage) { *failedStage = PHRuntimeStageSuperclass; }
        return nil;
    }

    NSArray<PHRuntimeObjCProtocolSnapshot *> *protocols = PHRuntimeProtocolSnapshotsForClass(cls, failedStage);
    if (!protocols && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCIvarSnapshot *> *ivars = PHRuntimeIvarSnapshotsForClass(cls, failedStage);
    if (!ivars && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCPropertySnapshot *> *classProperties = PHRuntimePropertySnapshotsForClass(cls, NO, PHRuntimeStageClassProperties, failedStage);
    if (!classProperties && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCPropertySnapshot *> *properties = PHRuntimePropertySnapshotsForClass(cls, YES, PHRuntimeStageProperties, failedStage);
    if (!properties && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCMethodSnapshot *> *classMethods = PHRuntimeMethodSnapshotsForClass(cls, NO, PHRuntimeStageClassMethods, failedStage);
    if (!classMethods && failedStage && *failedStage) { return nil; }
    NSArray<PHRuntimeObjCMethodSnapshot *> *methods = PHRuntimeMethodSnapshotsForClass(cls, YES, PHRuntimeStageMethods, failedStage);
    if (!methods && failedStage && *failedStage) { return nil; }

    return [[PHRuntimeObjCClassSnapshot alloc] initWithName:name
                                                    version:version
                                                  imageName:imageName
                                               instanceSize:instanceSize
                                             superClassName:superClassName
                                                  protocols:protocols ?: @[]
                                                      ivars:ivars ?: @[]
                                            classProperties:classProperties ?: @[]
                                                 properties:properties ?: @[]
                                               classMethods:classMethods ?: @[]
                                                    methods:methods ?: @[]];
}
@end
