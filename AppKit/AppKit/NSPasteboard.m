//
//  NSPasteboard.m
//  AppKit-iOS
//

#import "NSPasteboard.h"

NSPasteboardType const NSPasteboardTypeString = @"public.utf8-plain-text";
NSPasteboardType const NSPasteboardTypeHTML = @"public.html";
NSPasteboardType const NSPasteboardTypeRTF = @"public.rtf";
NSPasteboardType const NSPasteboardTypePNG = @"public.png";
NSPasteboardType const NSPasteboardTypeTIFF = @"public.tiff";
NSPasteboardType const NSPasteboardTypeURL = @"public.url";
NSPasteboardType const NSPasteboardTypeFileURL = @"public.file-url";

NSPasteboardName const NSPasteboardNameGeneral = @"Apple CFPasteboard general";

static NSData *NSPasteboardDataFromValue(id value) {
    if ([value isKindOfClass:[NSData class]]) return value;
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
    if ([value isKindOfClass:[NSURL class]]) return [[(NSURL *)value absoluteString] dataUsingEncoding:NSUTF8StringEncoding];
    return nil;
}

static NSString *NSPasteboardStringFromValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSData class]]) return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    return nil;
}

static BOOL NSPasteboardTypeIsText(NSPasteboardType type) {
    return [type isEqualToString:NSPasteboardTypeString] || [type isEqualToString:@"public.plain-text"] ||
           [type isEqualToString:@"public.text"] || [type isEqualToString:@"NSStringPboardType"];
}

#pragma mark - NSPasteboardItem

@implementation NSPasteboardItem {
    NSMutableDictionary<NSPasteboardType, id> *_values;
}

- (instancetype)init {
    return [self initWithValues:@{}];
}

- (instancetype)initWithValues:(NSDictionary<NSPasteboardType, id> *)values {
    self = [super init];
    if (self) {
        _values = [values mutableCopy];
    }
    return self;
}

- (NSDictionary<NSPasteboardType, id> *)values {
    return [_values copy];
}

- (NSArray<NSPasteboardType> *)types {
    return _values.allKeys;
}

- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type {
    if (!data || !type) return NO;
    _values[type] = data;
    return YES;
}

- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)type {
    if (!string || !type) return NO;
    _values[type] = [string copy];
    return YES;
}

- (NSData *)dataForType:(NSPasteboardType)type {
    return NSPasteboardDataFromValue(_values[type]);
}

- (NSString *)stringForType:(NSPasteboardType)type {
    id value = _values[type];
    if (!value && NSPasteboardTypeIsText(type)) {
        for (NSPasteboardType key in _values) {
            if (NSPasteboardTypeIsText(key)) return NSPasteboardStringFromValue(_values[key]);
        }
    }
    return NSPasteboardStringFromValue(value);
}

- (NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types {
    for (NSPasteboardType type in types) {
        if (_values[type]) return type;
    }
    return nil;
}

@end

#pragma mark - NSPasteboard

@implementation NSPasteboard {
    UIPasteboard *_pasteboard;
    NSPasteboardName _name;
}

+ (NSPasteboard *)generalPasteboard {
    return [self pasteboardWithName:NSPasteboardNameGeneral];
}

+ (NSPasteboard *)pasteboardWithName:(NSPasteboardName)name {
    static NSMutableDictionary<NSPasteboardName, NSPasteboard *> *pasteboards;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pasteboards = [NSMutableDictionary dictionary];
    });
    @synchronized (pasteboards) {
        NSPasteboard *pasteboard = pasteboards[name];
        if (!pasteboard) {
            pasteboard = [[NSPasteboard alloc] initWithName:name];
            pasteboards[name] = pasteboard;
        }
        return pasteboard;
    }
}

- (instancetype)initWithName:(NSPasteboardName)name {
    self = [super init];
    if (self) {
        _name = [name copy];
        if ([name isEqualToString:NSPasteboardNameGeneral]) {
            _pasteboard = [UIPasteboard generalPasteboard];
        } else {
            _pasteboard = [UIPasteboard pasteboardWithName:name create:YES];
        }
    }
    return self;
}

- (NSPasteboardName)name {
    return _name;
}

- (NSInteger)changeCount {
    return _pasteboard.changeCount;
}

- (NSArray<NSPasteboardType> *)types {
    return _pasteboard.pasteboardTypes;
}

- (NSArray<NSPasteboardItem *> *)pasteboardItems {
    NSMutableArray<NSPasteboardItem *> *items = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *item in _pasteboard.items) {
        [items addObject:[[NSPasteboardItem alloc] initWithValues:item]];
    }
    return items;
}

- (NSInteger)clearContents {
    _pasteboard.items = @[];
    return _pasteboard.changeCount;
}

- (NSInteger)declareTypes:(NSArray<NSPasteboardType> *)newTypes owner:(id)newOwner {
    return [self clearContents];
}

- (BOOL)writeObjects:(NSArray *)objects {
    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray arrayWithArray:_pasteboard.items];
    for (id object in objects) {
        if ([object isKindOfClass:[NSString class]]) {
            [items addObject:@{ NSPasteboardTypeString: object }];
        } else if ([object isKindOfClass:[NSURL class]]) {
            NSURL *url = object;
            [items addObject:@{ url.isFileURL ? NSPasteboardTypeFileURL : NSPasteboardTypeURL: url }];
        } else if ([object isKindOfClass:[NSPasteboardItem class]]) {
            [items addObject:[(NSPasteboardItem *)object values]];
        } else {
            return NO;
        }
    }
    _pasteboard.items = items;
    return YES;
}

- (NSArray *)readObjectsForClasses:(NSArray<Class> *)classArray options:(NSDictionary *)options {
    NSMutableArray *objects = [NSMutableArray array];
    for (NSPasteboardItem *item in self.pasteboardItems) {
        for (Class cls in classArray) {
            if (cls == [NSString class] || [cls isSubclassOfClass:[NSString class]]) {
                NSString *string = [item stringForType:NSPasteboardTypeString];
                if (string) { [objects addObject:string]; break; }
            } else if (cls == [NSURL class]) {
                NSString *string = [item stringForType:NSPasteboardTypeFileURL] ?: [item stringForType:NSPasteboardTypeURL];
                NSURL *url = string ? [NSURL URLWithString:string] : nil;
                if (url) { [objects addObject:url]; break; }
            } else if (cls == [NSPasteboardItem class]) {
                [objects addObject:item];
                break;
            }
        }
    }
    return objects;
}

- (BOOL)canReadObjectForClasses:(NSArray<Class> *)classArray options:(NSDictionary *)options {
    return [self readObjectsForClasses:classArray options:options].count > 0;
}

- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)dataType {
    return [self setValue:data forPasteboardType:dataType];
}

// UIPasteboard items hold NSData or property-list values (NSString, NSURL) per type.
- (BOOL)setValue:(id)data forPasteboardType:(NSPasteboardType)dataType {
    if (!dataType) return NO;
    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray arrayWithArray:_pasteboard.items];
    NSMutableDictionary<NSString *, id> *first = [(items.firstObject ?: @{}) mutableCopy];
    if (data) {
        first[dataType] = data;
    } else {
        [first removeObjectForKey:dataType];
    }
    if (items.count > 0) {
        items[0] = first;
    } else {
        [items addObject:first];
    }
    _pasteboard.items = items;
    return YES;
}

- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)dataType {
    if (!string) return NO;
    if (NSPasteboardTypeIsText(dataType)) {
        return [self setValue:[string copy] forPasteboardType:NSPasteboardTypeString];
    }
    return [self setData:[string dataUsingEncoding:NSUTF8StringEncoding] forType:dataType];
}

- (NSData *)dataForType:(NSPasteboardType)dataType {
    return self.pasteboardItems.firstObject ? [self.pasteboardItems.firstObject dataForType:dataType] : nil;
}

- (NSString *)stringForType:(NSPasteboardType)dataType {
    if (NSPasteboardTypeIsText(dataType)) {
        return _pasteboard.string;
    }
    return [self.pasteboardItems.firstObject stringForType:dataType];
}

- (NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types {
    NSArray<NSPasteboardType> *available = self.types;
    for (NSPasteboardType type in types) {
        if ([available containsObject:type]) return type;
        if (NSPasteboardTypeIsText(type) && _pasteboard.hasStrings) return type;
    }
    return nil;
}

@end
