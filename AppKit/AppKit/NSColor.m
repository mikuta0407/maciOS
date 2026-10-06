//
//  NSColor.m
//  AppKit
//
//  Created by Stossy11 on 25/08/2025.
//


#import "NSColor.h"
#import <UIKit/UIKit.h>

@implementation NSColor {
    UIColor *_backing;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithUIColor:(UIColor*)c {
    if ((self=[super init])) {
        _backing = c;
    }
    return self;
}

+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return [[self alloc] initWithUIColor:[UIColor colorWithRed:r green:g blue:b alpha:a]];
}

+ (NSColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a {
    return [[self alloc] initWithUIColor:[UIColor colorWithWhite:w alpha:a]];
}

+ (NSColor *)colorWithHue:(CGFloat)h saturation:(CGFloat)s brightness:(CGFloat)b alpha:(CGFloat)a {
    return [[self alloc] initWithUIColor:[UIColor colorWithHue:h saturation:s brightness:b alpha:a]];
}

+ (NSColor *)colorWithCGColor:(CGColorRef)cgColor {
    return [[self alloc] initWithUIColor:[UIColor colorWithCGColor:cgColor]];
}

#define MAKE(name) + (NSColor*)name##Color { return [[self alloc] initWithUIColor:[UIColor name##Color]]; }
MAKE(black)
MAKE(white)
MAKE(gray)
MAKE(red)
MAKE(green)
MAKE(blue)
MAKE(yellow)
MAKE(clear)
#undef MAKE

+ (NSColor *)lightGrayColor;{
    return [[self alloc] initWithUIColor:[UIColor lightGrayColor]];
}


+ (NSColor *)systemRedColor {
    return [[self alloc] initWithUIColor:[UIColor systemRedColor]];
}

+ (NSColor *)systemGreenColor {
    return [[self alloc] initWithUIColor:[UIColor systemGreenColor]];
}

+ (NSColor *)systemBlueColor {
    return [[self alloc] initWithUIColor:[UIColor systemBlueColor]];
}

+ (NSColor *)systemYellowColor {
    return [[self alloc] initWithUIColor:[UIColor systemYellowColor]];
}

+ (NSColor *)systemOrangeColor {
    return [[self alloc] initWithUIColor:[UIColor systemOrangeColor]];
}

+ (NSColor *)systemPinkColor {
    return [[self alloc] initWithUIColor:[UIColor systemPinkColor]];
}

+ (NSColor *)systemPurpleColor {
    return [[self alloc] initWithUIColor:[UIColor systemPurpleColor]];
}

+ (NSColor *)systemTealColor {
    return [[self alloc] initWithUIColor:[UIColor systemTealColor]];
}

+ (NSColor *)systemIndigoColor {
    return [[self alloc] initWithUIColor:[UIColor systemIndigoColor]];
}

+ (NSColor *)systemBrownColor {
    return [[self alloc] initWithUIColor:[UIColor systemBrownColor]];
}

+ (NSColor *)systemMintColor {
    if (@available(iOS 15.0, *)) {
        return [[self alloc] initWithUIColor:[UIColor systemMintColor]];
    } else if (@available(iOS 13.0, *)) {
        return [[self alloc] initWithUIColor:[UIColor systemTealColor]];
    } else {
        return [[self alloc] initWithUIColor:[UIColor cyanColor]];
    }
}

+ (NSColor *)systemCyanColor {
    if (@available(iOS 15.0, *)) {
        return [[self alloc] initWithUIColor:[UIColor systemCyanColor]];
    } else if (@available(iOS 13.0, *)) {
        return [[self alloc] initWithUIColor:[UIColor systemTealColor]];
    } else {
        return [[self alloc] initWithUIColor:[UIColor cyanColor]];
    }
}

+ (NSColor *)labelColor {
    return [[self alloc] initWithUIColor:[UIColor labelColor]];
}

+ (NSColor *)secondaryLabelColor {
    return [[self alloc] initWithUIColor:[UIColor secondaryLabelColor]];
}

+ (NSColor *)tertiaryLabelColor {
    return [[self alloc] initWithUIColor:[UIColor tertiaryLabelColor]];
}

+ (NSColor *)quaternaryLabelColor {
    return [[self alloc] initWithUIColor:[UIColor quaternaryLabelColor]];
}

+ (NSColor *)systemBackgroundColor {
    return [[self alloc] initWithUIColor:[UIColor systemBackgroundColor]];
}

+ (NSColor *)secondarySystemBackgroundColor {
    return [[self alloc] initWithUIColor:[UIColor secondarySystemBackgroundColor]];
}

+ (NSColor *)tertiarySystemBackgroundColor {
    return [[self alloc] initWithUIColor:[UIColor tertiarySystemBackgroundColor]];
}

+ (NSColor *)systemGroupedBackgroundColor {
    return [[self alloc] initWithUIColor:[UIColor systemGroupedBackgroundColor]];
}

+ (NSColor *)secondarySystemGroupedBackgroundColor {
    return [[self alloc] initWithUIColor:[UIColor secondarySystemGroupedBackgroundColor]];
}

+ (NSColor *)tertiarySystemGroupedBackgroundColor {
    return [[self alloc] initWithUIColor:[UIColor tertiarySystemGroupedBackgroundColor]];
}

+ (NSColor *)systemFillColor {
    return [[self alloc] initWithUIColor:[UIColor systemFillColor]];
}

+ (NSColor *)secondarySystemFillColor {
    return [[self alloc] initWithUIColor:[UIColor secondarySystemFillColor]];
}

+ (NSColor *)tertiarySystemFillColor {
    return [[self alloc] initWithUIColor:[UIColor tertiarySystemFillColor]];
}

+ (NSColor *)quaternarySystemFillColor {
    return [[self alloc] initWithUIColor:[UIColor quaternarySystemFillColor]];
}

+ (NSColor *)separatorColor {
    return [[self alloc] initWithUIColor:[UIColor separatorColor]];
}

+ (NSColor *)opaqueSeparatorColor {
    return [[self alloc] initWithUIColor:[UIColor opaqueSeparatorColor]];
}

+ (NSColor *)linkColor {
    return [[self alloc] initWithUIColor:[UIColor linkColor]];
}

+ (NSColor *)placeholderTextColor {
    return [[self alloc] initWithUIColor:[UIColor placeholderTextColor]];
}

+ (NSColor *)controlAccentColor {
    if (@available(iOS 14.0, *)) {
        return [[self alloc] initWithUIColor:[UIColor tintColor]];
    } else if (@available(iOS 13.0, *)) {
        return [[self alloc] initWithUIColor:[UIColor systemBlueColor]];
    } else {
        return [[self alloc] initWithUIColor:[UIColor blueColor]];
    }
}

- (CGColorRef)CGColor {
    return _backing.CGColor;
}

- (UIColor*)uiColor {
    return _backing;
}

- (CGFloat)redComponent {
    CGFloat r,g,b,a;
    [_backing getRed:&r green:&g blue:&b alpha:&a];
    return r;
}

- (CGFloat)greenComponent {
    CGFloat r,g,b,a;
    [_backing getRed:&r green:&g blue:&b alpha:&a];
    return g;
}

- (CGFloat)blueComponent {
    CGFloat r,g,b,a;
    [_backing getRed:&r green:&g blue:&b alpha:&a];
    return b;
}

- (CGFloat)alphaComponent {
    return CGColorGetAlpha(_backing.CGColor);
}

- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha {
    return [[NSColor alloc] initWithUIColor:[_backing colorWithAlphaComponent:alpha]];
}

- (NSColor *)blendedColorWithFraction:(CGFloat)fraction ofColor:(NSColor *)color {
    if (!color) return self;

    CGFloat r1, g1, b1, a1;
    CGFloat r2, g2, b2, a2;

    [_backing getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [color.uiColor getRed:&r2 green:&g2 blue:&b2 alpha:&a2];

    CGFloat r = r1 + (r2 - r1) * fraction;
    CGFloat g = g1 + (g2 - g1) * fraction;
    CGFloat b = b1 + (b2 - b1) * fraction;
    CGFloat a = a1 + (a2 - a1) * fraction;

    return [NSColor colorWithRed:r green:g blue:b alpha:a];
}

- (id)copyWithZone:(NSZone*)z {
    return [[NSColor allocWithZone:z] initWithUIColor:_backing];
}

- (void)encodeWithCoder:(NSCoder*)c {
    CGFloat r,g,b,a;
    [_backing getRed:&r green:&g blue:&b alpha:&a];
    [c encodeDouble:r forKey:@"r"];
    [c encodeDouble:g forKey:@"g"];
    [c encodeDouble:b forKey:@"b"];
    [c encodeDouble:a forKey:@"a"];
}

- (instancetype)initWithCoder:(NSCoder*)c {
    return [NSColor colorWithRed:[c decodeDoubleForKey:@"r"]
                           green:[c decodeDoubleForKey:@"g"]
                            blue:[c decodeDoubleForKey:@"b"]
                           alpha:[c decodeDoubleForKey:@"a"]];
}

- (NSString *)description {
    CGFloat r, g, b, a;
    [_backing getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"NSColor(r:%0.3f g:%0.3f b:%0.3f a:%0.3f)", r, g, b, a];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *signature = [super methodSignatureForSelector:aSelector];
    if (!signature) {
        signature = [_backing methodSignatureForSelector:aSelector];
    }
    return signature;
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    if ([_backing respondsToSelector:[anInvocation selector]]) {
        [anInvocation invokeWithTarget:_backing];
    } else {
        [super forwardInvocation:anInvocation];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [_backing respondsToSelector:aSelector];
}

- (UIColor *)resolvedColorWithTraitCollection:(UITraitCollection *)traitCollection API_AVAILABLE(ios(13.0)) {
    if (@available(iOS 13.0, *)) {
        UIColor *resolved = [_backing resolvedColorWithTraitCollection:traitCollection];
        return resolved;
    }
    return _backing;
}


- (UIColor *)_resolvedBackgroundColorWithTraitCollection:(UITraitCollection *)traitCollection {
    if (@available(iOS 13.0, *)) {
        if ([_backing respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
            return [_backing resolvedColorWithTraitCollection:traitCollection];
        }
    }
    return _backing;
}

+ (NSColor *)colorWithDynamicProvider:(UIColor * (^)(UITraitCollection *))dynamicProvider API_AVAILABLE(ios(13.0)) {
    if (@available(iOS 13.0, *)) {
        UIColor *dynamicColor = [UIColor colorWithDynamicProvider:dynamicProvider];
        return [[self alloc] initWithUIColor:dynamicColor];
    } else {

        return [[self alloc] initWithUIColor:dynamicProvider(nil)];
    }
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[NSColor class]]) return NO;

    NSColor *otherColor = (NSColor *)object;
    return [_backing isEqual:otherColor.uiColor];
}

- (NSUInteger)hash {
    return [_backing hash];
}

@end
