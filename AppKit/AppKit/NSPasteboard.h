//
//  NSPasteboard.h
//  AppKit-iOS
//
//  NSPasteboard backed by UIPasteboard.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString * NSPasteboardType NS_TYPED_EXTENSIBLE_ENUM;
typedef NSString * NSPasteboardName NS_TYPED_EXTENSIBLE_ENUM;

FOUNDATION_EXPORT NSPasteboardType const NSPasteboardTypeString;
FOUNDATION_EXPORT NSPasteboardType const NSPasteboardTypeHTML;
FOUNDATION_EXPORT NSPasteboardType const NSPasteboardTypeRTF;
FOUNDATION_EXPORT NSPasteboardType const NSPasteboardTypePNG;
FOUNDATION_EXPORT NSPasteboardType const NSPasteboardTypeTIFF;
FOUNDATION_EXPORT NSPasteboardType const NSPasteboardTypeURL;
FOUNDATION_EXPORT NSPasteboardType const NSPasteboardTypeFileURL;

FOUNDATION_EXPORT NSPasteboardName const NSPasteboardNameGeneral;

@interface NSPasteboardItem : NSObject

@property (nonatomic, readonly, copy) NSArray<NSPasteboardType> *types;

- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type;
- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)type;
- (nullable NSData *)dataForType:(NSPasteboardType)type;
- (nullable NSString *)stringForType:(NSPasteboardType)type;
- (nullable NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types;

@end

@interface NSPasteboard : NSObject

@property (class, readonly, strong) NSPasteboard *generalPasteboard;
@property (readonly, copy) NSPasteboardName name;
@property (readonly) NSInteger changeCount;
@property (nullable, readonly, copy) NSArray<NSPasteboardType> *types;
@property (nullable, readonly, copy) NSArray<NSPasteboardItem *> *pasteboardItems;

+ (NSPasteboard *)pasteboardWithName:(NSPasteboardName)name;

- (NSInteger)clearContents;
- (NSInteger)declareTypes:(NSArray<NSPasteboardType> *)newTypes owner:(nullable id)newOwner;
- (BOOL)writeObjects:(NSArray *)objects;
- (nullable NSArray *)readObjectsForClasses:(NSArray<Class> *)classArray options:(nullable NSDictionary *)options;
- (BOOL)canReadObjectForClasses:(NSArray<Class> *)classArray options:(nullable NSDictionary *)options;

- (BOOL)setData:(nullable NSData *)data forType:(NSPasteboardType)dataType;
- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)dataType;
- (nullable NSData *)dataForType:(NSPasteboardType)dataType;
- (nullable NSString *)stringForType:(NSPasteboardType)dataType;
- (nullable NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types;

@end

NS_ASSUME_NONNULL_END
