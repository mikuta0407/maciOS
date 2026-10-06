//
//  CodeSignatureRehash.h
//  maciOS
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Recomputes the code page hashes of every CodeDirectory in the file's
/// existing (ad-hoc or linker) code signature, in place, so the signature
/// matches the patched contents again. Handles thin and fat Mach-O files.
BOOL macho_rehash_code_signature(NSString *path);

NS_ASSUME_NONNULL_END
