#import "GMQuickReplies.h"

static NSString *const kKey = @"quick.replies";

@implementation GMQuickReplies

+ (NSArray *)all {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:kKey] ?: @[];
    return [a sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        return [[x objectForKey:@"k"] compare:[y objectForKey:@"k"]];
    }];
}

+ (NSString *)normalize:(NSString *)keyword {
    NSString *k = [[keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    while ([k hasPrefix:@"/"]) k = [k substringFromIndex:1];
    return [[k componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@"_"];
}

+ (void)save:(NSString *)keyword text:(NSString *)text {
    NSString *k = [self normalize:keyword];
    if (!k.length || !text.length) return;
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *d in [self all]) {
        if (![[d objectForKey:@"k"] isEqual:k]) [a addObject:d];
    }
    [a addObject:@{@"k": k, @"t": text}];
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:kKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)remove:(NSString *)keyword {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *d in [self all]) {
        if (![[d objectForKey:@"k"] isEqual:keyword]) [a addObject:d];
    }
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:kKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
