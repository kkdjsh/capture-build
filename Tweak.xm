// Tweak.xm - 抓包插件 v13
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL enableCapture = NO;
static NSMutableArray *reqs;
static const int MAX_REQS = 200;
static NSMutableArray *rules;
static NSMutableArray *blacklist;

static void saveBlacklist() {
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    path = [path stringByAppendingPathComponent:@"cap_blacklist.plist"];
    [blacklist writeToFile:path atomically:YES];
}
static void loadBlacklist() {
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    path = [path stringByAppendingPathComponent:@"cap_blacklist.plist"];
    NSArray *arr = [NSArray arrayWithContentsOfFile:path];
    if (arr) blacklist = [NSMutableArray arrayWithArray:arr];
}
static BOOL isBlacklisted(NSString *url) {
    if (!blacklist) return NO;
    for (NSString *b in blacklist) { if ([url containsString:b]) return YES; }
    return NO;
}

static void addReq(NSDictionary *r) {
    if (!reqs) reqs = [NSMutableArray new];
    [reqs addObject:r];
    if (reqs.count > MAX_REQS) [reqs removeObjectsInRange:NSMakeRange(0, reqs.count-MAX_REQS)];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CapNewReq" object:nil];
}

static id jsonSetPath(id obj, NSArray *parts, id value) {
    if (parts.count == 0) return value;
    NSString *head = parts[0];
    NSMutableArray *rest = [parts subarrayWithRange:NSMakeRange(1, parts.count-1)].mutableCopy;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [obj mutableCopy];
        d[head] = jsonSetPath(d[head] ?: @{}, rest, value);
        return d;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [obj mutableCopy];
        NSInteger idx = head.integerValue;
        if (idx >= 0 && idx < a.count) {
            a[idx] = jsonSetPath(a[idx] ?: @{}, rest, value);
        }
        return a;
    }
    return obj;
}

static NSString* applyJsonPath(NSString *body, NSString *path, NSString *value) {
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!obj) return body;
    // normalize path
    NSString *p = path;
    if ([p hasPrefix:@"$."]) p = [p substringFromIndex:2];
    else if ([p hasPrefix:@"$"]) p = [p substringFromIndex:1];
    NSArray *parts = [p componentsSeparatedByString:@"."];
    // infer type
    id v = value;
    if ([value isKindOfClass:[NSString class]]) {
        if ([value isEqualToString:@"null"]) v = [NSNull null];
        else if ([value isEqualToString:@"true"]) v = @YES;
        else if ([value isEqualToString:@"false"]) v = @NO;
        else {
            NSInteger i; NSScanner *sc = [NSScanner scannerWithString:value];
            if ([sc scanInteger:&i] && sc.isAtEnd) v = @(i);
            else { double d; if ([sc scanDouble:&d] && sc.isAtEnd) v = @(d); }
        }
    }
    id newObj = jsonSetPath(obj, parts, v);
    NSData *out = [NSJSONSerialization dataWithJSONObject:newObj options:0 error:nil];
    return out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : body;
}

static NSString* autoDetectMode(NSString *find) {
    if (!find.length) return @"text";
    // 1. explicit jsonpath prefix
    if ([find hasPrefix:@"$."]) return @"jsonpath";
    // 2. multi-level dot path like data.unreadNum, no other regex chars -> jsonpath
    NSUInteger dots = [[find componentsSeparatedByString:@"."] count] - 1;
    NSCharacterSet *strongRegex = [NSCharacterSet characterSetWithCharactersInString:@"*+?()[]|\\^$"];
    BOOL hasStrong = [find rangeOfCharacterFromSet:strongRegex].location != NSNotFound;
    if (dots >= 1 && !hasStrong) return @"jsonpath";
    // 3. regex chars
    NSCharacterSet *regexChars = [NSCharacterSet characterSetWithCharactersInString:@".*+?[]()\\|"];
    if ([find rangeOfCharacterFromSet:regexChars].location != NSNotFound) return @"regex";
    return @"text";
}

static NSString* applyFindReplace(NSString *body, NSString *find, NSString *replace) {
    if (!find.length) return body;
    NSString *mt = autoDetectMode(find);
    if ([mt isEqualToString:@"regex"]) {
        NSError *err = nil;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:find options:0 error:&err];
        if (re && !err) {
            body = [re stringByReplacingMatchesInString:body options:0 range:NSMakeRange(0, body.length) withTemplate:replace?:@""];
        }
    } else if ([mt isEqualToString:@"jsonpath"]) {
        body = applyJsonPath(body, find, replace);
    } else {
        if ([body containsString:find]) {
            body = [body stringByReplacingOccurrencesOfString:find withString:replace?:@""];
        }
    }
    return body;
}

static NSString* applyRules(NSString *body, NSString *url, NSString *dir, BOOL *modified, NSMutableArray *hits) {
    if (!rules) return body;
    BOOL didModify = NO;
    for (NSDictionary *rule in rules) {
        NSString *d = rule[@"dir"] ?: @"resp";
        if (![d isEqualToString:dir]) continue;
        NSString *u = rule[@"url"];
        if (u.length && ![url containsString:u]) continue;
        NSArray *items = rule[@"items"];
        for (NSDictionary *item in items) {
            if (item[@"action"] && ![item[@"action"] isEqualToString:@"body"]) continue;
            NSString *orig = body;
            body = applyFindReplace(body, item[@"find"], item[@"replace"]);
            if (![body isEqualToString:orig]) {
                didModify = YES;
                if (hits && item[@"replace"]) {
                    NSString *mt = autoDetectMode(item[@"find"] ?: @"");
                    if ([mt isEqualToString:@"jsonpath"]) {
                        // extract last key component
                        NSString *p = item[@"find"];
                        if ([p hasPrefix:@"$."]) p = [p substringFromIndex:2];
                        NSString *key = [p componentsSeparatedByString:@"."].lastObject;
                        [hits addObject:@{@"key": key ?: @"", @"val": item[@"replace"], @"mode": @"jsonpath"}];
                    } else if ([mt isEqualToString:@"regex"]) {
                        [hits addObject:@{@"val": item[@"replace"], @"mode": @"regex"}];
                    } else {
                        [hits addObject:@{@"val": item[@"replace"], @"mode": @"text"}];
                    }
                }
            }
        }
    }
    if (modified) *modified = didModify;
    return body;
}

static void saveRules() {
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    path = [path stringByAppendingPathComponent:@"cap_rules.plist"];
    [rules writeToFile:path atomically:YES];
}
static void loadRules() {
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    path = [path stringByAppendingPathComponent:@"cap_rules.plist"];
    NSArray *arr = [NSArray arrayWithContentsOfFile:path];
    if (arr) { rules = [NSMutableArray arrayWithArray:arr]; }
}

#pragma mark - Protocol

@interface CapProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@end
@implementation CapProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!enableCapture) return NO;
    if ([NSURLProtocol propertyForKey:@"capHandled" inRequest:request]) return NO;
    NSString *scheme = request.URL.scheme;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    NSString *path = request.URL.path.lowercaseString;
    // 跳过媒体和大文件，避免视频不播放和闪退
    NSArray *skipExt = @[@".mp4", @".m3u8", @".ts", @".m4s", @".avi", @".mov", @".mkv",
                         @".mp3", @".m4a", @".wav", @".flac",
                         @".jpg", @".jpeg", @".png", @".gif", @".webp", @".svg", @".ico",
                         @".css", @".js", @".woff", @".woff2", @".ttf", @".otf",
                         @".zip", @".ipa", @".dylib", @".framework"];
    for (NSString *ext in skipExt) {
        if ([path hasSuffix:ext]) return NO;
    }
    return YES;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    @try {
    // blacklist: drop
    if (isBlacklisted(self.request.URL.absoluteString)) {
        NSMutableDictionary *rec = [NSMutableDictionary new];
        rec[@"method"] = self.request.HTTPMethod ?: @"GET";
        rec[@"url"] = self.request.URL.absoluteString;
        rec[@"host"] = self.request.URL.host ?: @"";
        rec[@"path"] = self.request.URL.path ?: @"/";
        rec[@"status"] = @"DROP";
        rec[@"blacklisted"] = @YES;
        addReq(rec);
        NSError *err = [NSError errorWithDomain:@"CapBlacklist" code:-999 userInfo:nil];
        [self.client URLProtocol:self didFailWithError:err];
        return;
    }
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"capHandled" inRequest:req];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:@"" forHTTPHeaderField:@"Accept-Encoding"];

    // 请求体重写
    if (req.HTTPBody) {
        NSString *body = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
        BOOL mod = NO;
        body = applyRules(body, req.URL.absoluteString, @"req", &mod, nil);
        req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSMutableDictionary *rec = [NSMutableDictionary new];
    rec[@"method"] = req.HTTPMethod ?: @"GET";
    rec[@"url"] = req.URL.absoluteString;
    rec[@"host"] = req.URL.host ?: @"";
    rec[@"path"] = req.URL.path ?: @"/";
    rec[@"reqHeaders"] = req.allHTTPHeaderFields ?: @{};
    if (req.HTTPBody) rec[@"reqBody"] = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
    objc_setAssociatedObject(self, "rec", rec, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, "acc", [NSMutableData new], OBJC_ASSOCIATION_RETAIN);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.protocolClasses = @[]; // 不注入CapProtocol，避免递归
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSURLSessionDataTask *t = [s dataTaskWithRequest:req];
    objc_setAssociatedObject(self, "task", t, OBJC_ASSOCIATION_RETAIN);
    [t resume];
    } @catch (NSException *e) {
        NSLog(@"CapProtocol startLoading error: %@", e);
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"CapError" code:-1 userInfo:nil]];
    }
}
- (void)stopLoading { NSURLSessionDataTask *t = objc_getAssociatedObject(self, "task"); [t cancel]; }

- (void)URLSession:(NSURLSession *)ds dataTask:(NSURLSessionDataTask *)dt didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))ch {
    NSMutableDictionary *rec = objc_getAssociatedObject(self, "rec");
    rec[@"status"] = [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse*)response statusCode]];
    rec[@"respHeaders"] = [(NSHTTPURLResponse*)response allHeaderFields] ?: @{};
    objc_setAssociatedObject(self, "resp", response, OBJC_ASSOCIATION_RETAIN);
    ch(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)ds dataTask:(NSURLSessionDataTask *)dt didReceiveData:(NSData *)data {
    NSMutableData *acc = objc_getAssociatedObject(self, "acc");
    if (acc && data) [acc appendData:data];
}
- (void)URLSession:(NSURLSession *)ds task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSMutableDictionary *rec = objc_getAssociatedObject(self, "rec");
    NSMutableData *acc = objc_getAssociatedObject(self, "acc");
    NSURLResponse *resp = objc_getAssociatedObject(self, "resp");
    NSData *finalData = acc;
    if (acc.length) {
        NSString *body = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding] ?: @"";
        BOOL mod = NO;
        NSMutableArray *hits = [NSMutableArray new];
        body = applyRules(body, rec[@"url"], @"resp", &mod, hits);
        finalData = [body dataUsingEncoding:NSUTF8StringEncoding];
        rec[@"respBody"] = body;
        if (mod) { rec[@"rewritten"] = @YES; rec[@"hits"] = hits; }
    }
    addReq(rec);
    if (resp && [resp isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *hr = (NSHTTPURLResponse*)resp;
        NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:hr.allHeaderFields];
        h[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)finalData.length];
        [h removeObjectForKey:@"Content-Encoding"];
        NSHTTPURLResponse *nr = [[NSHTTPURLResponse alloc] initWithURL:hr.URL statusCode:hr.statusCode HTTPVersion:@"HTTP/1.1" headerFields:h];
        [self.client URLProtocol:self didReceiveResponse:nr cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    }
    if (finalData.length) [self.client URLProtocol:self didLoadData:finalData];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))ch {
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (trust) {
        ch(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    } else {
        ch(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}
@end

%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    NSMutableArray *arr = [NSMutableArray arrayWithArray:c.protocolClasses ?: @[]];
    if (![arr containsObject:[CapProtocol class]]) [arr insertObject:[CapProtocol class] atIndex:0];
    c.protocolClasses = arr; return c;
}
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    NSMutableArray *arr = [NSMutableArray arrayWithArray:c.protocolClasses ?: @[]];
    if (![arr containsObject:[CapProtocol class]]) [arr insertObject:[CapProtocol class] atIndex:0];
    c.protocolClasses = arr; return c;
}
%end

%hook NSObject
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else %orig;
}
%end

#pragma mark - 详情页
@interface ReqDetailVC : UIViewController
@property (nonatomic, strong) NSDictionary *rec;
@property (nonatomic, assign) BOOL prettyJson;
@property (nonatomic, strong) UIScrollView *sv;
@end
@implementation ReqDetailVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"请求详情";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"JSON" style:UIBarButtonItemStylePlain target:self action:@selector(toggleJson)];
    self.sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.sv.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.sv];
    [self render];
}
- (void)toggleJson { self.prettyJson = !self.prettyJson; [self render]; }
- (NSString*)fmtDict:(NSDictionary*)d {
    NSMutableString *s = [NSMutableString new];
    for (NSString *k in d) { [s appendFormat:@"%@: %@\n", k, d[k]]; }
    return s.length?s:@"(空)";
}
- (NSString*)fmtJson:(NSString*)raw {
    if (!self.prettyJson) return raw;
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!obj) return raw;
    NSData *out = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:nil];
    return out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : raw;
}
- (void)render {
    for (UIView *v in self.sv.subviews) [v removeFromSuperview];
    CGFloat y = 20;
    UIFont *mono = [UIFont fontWithName:@"Courier" size:11];
    NSArray *items = @[@"URL", @"Method", @"Status", @"请求头", @"请求体", @"响应头", @"响应体"];
    NSArray *keys = @[@"url", @"method", @"status", @"reqHeaders", @"reqBody", @"respHeaders", @"respBody"];
    for (int i = 0; i < items.count; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 300, 20)];
        l.text = items[i]; l.font = [UIFont boldSystemFontOfSize:14]; [self.sv addSubview:l]; y += 24;
        id v = self.rec[keys[i]];
        NSString *s;
        if ([v isKindOfClass:[NSDictionary class]]) s = [self fmtDict:v];
        else if (i == 6) s = [self fmtJson:(v ?: @"(空)")];
        else s = v ?: @"(空)";
        UITextView *v2 = [[UITextView alloc] initWithFrame:CGRectMake(16, y, self.view.frame.size.width-32, 0)];
        v2.font = mono; v2.scrollEnabled = NO; v2.editable = NO; v2.dataDetectorTypes = UIDataDetectorTypeNone;
        v2.textColor = [UIColor darkGrayColor]; v2.backgroundColor = [UIColor clearColor];
        if (i == 6 && self.rec[@"hits"]) {
            NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithString:s attributes:@{NSForegroundColorAttributeName:[UIColor darkGrayColor], NSFontAttributeName:mono}];
            for (NSDictionary *h in self.rec[@"hits"]) {
                NSString *mode = h[@"mode"] ?: @"text";
                NSString *val = h[@"val"] ?: @"";
                if (!val.length) continue;
                if ([mode isEqualToString:@"jsonpath"]) {
                    // highlight "key" : value  (with optional spaces and quotes)
                    NSString *key = h[@"key"] ?: @"";
                    // try patterns: "key" : val, "key": val, "key" : "val"
                    NSArray *variants = @[
                        [NSString stringWithFormat:@"\"%@\" : %@", key, val],
                        [NSString stringWithFormat:@"\"%@\":%@", key, val],
                        [NSString stringWithFormat:@"\"%@\" : \"%@\"", key, val],
                        [NSString stringWithFormat:@"\"%@\":\"%@\"", key, val],
                    ];
                    for (NSString *v in variants) {
                        NSRange r = [s rangeOfString:v];
                        if (r.location != NSNotFound) {
                            [mas addAttribute:NSForegroundColorAttributeName value:[UIColor systemRedColor] range:r];
                            [mas addAttribute:NSBackgroundColorAttributeName value:[UIColor systemYellowColor] range:r];
                            break;
                        }
                    }
                } else {
                    // regex/text: highlight the value itself
                    NSArray *variants = @[val, [NSString stringWithFormat:@"\"%@\"", val]];
                    for (NSString *v in variants) {
                        NSRange r = [s rangeOfString:v];
                        while (r.location != NSNotFound) {
                            [mas addAttribute:NSForegroundColorAttributeName value:[UIColor systemRedColor] range:r];
                            [mas addAttribute:NSBackgroundColorAttributeName value:[UIColor systemYellowColor] range:r];
                            NSUInteger next = r.location + r.length;
                            if (next >= s.length) break;
                            r = [s rangeOfString:v options:0 range:NSMakeRange(next, s.length-next)];
                        }
                    }
                }
            }
            v2.attributedText = mas;
        } else {
            v2.text = s;
        }
        CGSize sz = [v2 sizeThatFits:CGSizeMake(self.view.frame.size.width-32, 100000)];
        v2.frame = CGRectMake(16, y, sz.width, sz.height);
        [self.sv addSubview:v2]; y += sz.height + 16;
    }
    self.sv.contentSize = CGSizeMake(self.view.frame.size.width, y+40);
}
@end

#pragma mark - 规则编辑页
@interface RuleEditVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableDictionary *rule;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UISegmentedControl *seg;
@end
@implementation RuleEditVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"编辑规则";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    CGFloat y = 80;
    // 方向
    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"响应", @"请求"]];
    self.seg.frame = CGRectMake(16, y, self.view.frame.size.width-32, 30);
    self.seg.selectedSegmentIndex = [self.rule[@"dir"] isEqualToString:@"req"] ? 1 : 0;
    [self.view addSubview:self.seg]; y += 50;
    // 名称
    self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(16, y, self.view.frame.size.width-32, 36)];
    self.nameField.borderStyle = UITextBorderStyleRoundedRect; self.nameField.placeholder = @"名称(备注)";
    self.nameField.text = self.rule[@"name"]; [self.view addSubview:self.nameField]; y += 46;
    // URL
    self.urlField = [[UITextField alloc] initWithFrame:CGRectMake(16, y, self.view.frame.size.width-32, 36)];
    self.urlField.borderStyle = UITextBorderStyleRoundedRect; self.urlField.placeholder = @"URL包含(空=全部)";
    self.urlField.text = self.rule[@"url"]; [self.view addSubview:self.urlField]; y += 50;
    // 子规则列表标题(左侧)
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 200, 20)];
    l.text = @"查找替换规则"; l.font = [UIFont boldSystemFontOfSize:14]; [self.view addSubview:l];
    // 加子规则按钮(右侧)
    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.frame = CGRectMake(self.view.frame.size.width-116, y-4, 100, 28);
    addBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [addBtn setTitle:@"+ 添加" forState:UIControlStateNormal];
    [addBtn addTarget:self action:@selector(addItem) forControlEvents:UIControlEventTouchUpInside];
    addBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [self.view addSubview:addBtn]; y += 28;
    // 子规则表
    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, y, self.view.frame.size.width, self.view.frame.size.height-y)];
    self.tv.dataSource = self; self.tv.delegate = self;
    [self.tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.tv];
}
- (void)addItem {
    NSMutableArray *items = self.rule[@"items"];
    if (![items isKindOfClass:[NSMutableArray class]]) items = [NSMutableArray array];
    [items addObject:[@{@"find":@"", @"replace":@"", @"matchType":@"regex"} mutableCopy]];
    self.rule[@"items"] = items;
    [self.tv reloadData];
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return [self.rule[@"items"] count]; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *item = self.rule[@"items"][ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@  ->  %@", item[@"find"], item[@"replace"]];
    c.textLabel.font = [UIFont systemFontOfSize:12];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    NSMutableDictionary *item = self.rule[@"items"][ip.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"查找替换" message:@"自动识别: 多级key=JSON路径, 含.*+=?=正则, 其余文本" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"查找/JSON路径(如data.unreadNum)";f.text=item[@"find"];}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"替换值";f.text=item[@"replace"];}];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction*_){
        NSString *f = a.textFields[0].text ?: @"";
        NSString *r = a.textFields[1].text ?: @"";
        if (!f.length) {
            UIAlertController *e = [UIAlertController alertControllerWithTitle:@"识别失败" message:@"请检查输入内容" preferredStyle:UIAlertControllerStyleAlert];
            [self presentViewController:e animated:YES completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [e dismissViewControllerAnimated:YES completion:nil]; });
            }];
            return;
        }
        item[@"find"]=f; item[@"replace"]=r; item[@"action"]=@"body";
        [self.tv reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView*)t commitEditingStyle:(UITableViewCellEditingStyle)e forRowAtIndexPath:(NSIndexPath*)ip {
    if (e == UITableViewCellEditingStyleDelete) { [self.rule[@"items"] removeObjectAtIndex:ip.row]; [self.tv reloadData]; }
}
- (void)save {
    self.rule[@"dir"] = self.seg.selectedSegmentIndex == 1 ? @"req" : @"resp";
    self.rule[@"name"] = self.nameField.text ?: @"";
    self.rule[@"url"] = self.urlField.text ?: @"";
    saveRules();
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - 规则列表
@interface RuleListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tv;
@end
@implementation RuleListVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"重写规则";
    self.view.backgroundColor = [UIColor whiteColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(add)];
    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tv.dataSource = self; self.tv.delegate = self;
    [self.tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.tv];
}
- (void)viewWillAppear:(BOOL)animated { [self.tv reloadData]; }
- (void)add {
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:@{@"url":@"",@"name":@"",@"dir":@"resp",@"items":[NSMutableArray new]}];
    [rules addObject:r];
    RuleEditVC *vc = [[RuleEditVC alloc] init];
    vc.rule = r;
    [self.navigationController pushViewController:vc animated:YES];
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return rules.count; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *r = rules[ip.row];
    NSString *dir = [r[@"dir"] isEqualToString:@"req"] ? @"请求" : @"响应";
    NSString *name = r[@"name"];
    NSInteger cnt = [r[@"items"] count];
    c.textLabel.text = [NSString stringWithFormat:@"%@\n[%@] %ld条子规则  URL:%@", name.length?name:r[@"url"], [r[@"dir"] isEqualToString:@"req"]?@"请求":@"响应", (long)cnt, r[@"url"]];
    c.textLabel.numberOfLines = 2; c.textLabel.font = [UIFont systemFontOfSize:12];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    RuleEditVC *vc = [[RuleEditVC alloc] init];
    vc.rule = rules[ip.row];
    [self.navigationController pushViewController:vc animated:YES];
}
- (void)tableView:(UITableView*)t commitEditingStyle:(UITableViewCellEditingStyle)e forRowAtIndexPath:(NSIndexPath*)ip {
    if (e == UITableViewCellEditingStyleDelete) { [rules removeObjectAtIndex:ip.row]; saveRules(); [self.tv reloadData]; }
}
@end

#pragma mark - 规则文本编辑器
@interface RuleTextEditorVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@end
@implementation RuleTextEditorVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"规则文本编辑器";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"导入" style:UIBarButtonItemStyleDone target:self action:@selector(doImport)],
        [[UIBarButtonItem alloc] initWithTitle:@"导出" style:UIBarButtonItemStylePlain target:self action:@selector(doExport)]
    ];
    self.tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.tv.font = [UIFont fontWithName:@"Courier" size:12];
    self.tv.text = @"// 粘贴规则JSON，或点导出查看当前规则格式";
    [self.view addSubview:self.tv];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)doExport {
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *r in rules) {
        NSMutableArray *items = [NSMutableArray new];
        for (NSDictionary *it in r[@"items"]) {
            [items addObject:@{@"matchType":it[@"matchType"]?:@"text", @"find":it[@"find"]?:@"", @"replace":it[@"replace"]?:@""}];
        }
        [out addObject:@{@"name":r[@"name"]?:@"", @"url":r[@"url"]?:@"", @"direction":[r[@"dir"] isEqualToString:@"req"]?@"request":@"response", @"rules":items}];
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    self.tv.text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}
- (void)doImport {
    NSData *d = [self.tv.text dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (!arr) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JSON错误" message:@"格式不正确" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil]; return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导入" message:@"覆盖现有规则还是追加？" preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"覆盖" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*_){
        NSMutableArray *nr = [NSMutableArray new];
        for (NSDictionary *o in arr) {
            NSMutableDictionary *r = [NSMutableDictionary new];
            r[@"url"] = o[@"url"]?:@""; r[@"name"] = o[@"name"]?:@"";
            r[@"dir"] = [o[@"direction"] isEqualToString:@"request"]?@"req":@"resp";
            NSMutableArray *items = [NSMutableArray new];
            for (NSDictionary *it in o[@"rules"]) {
                [items addObject:[@{@"matchType":it[@"matchType"]?:@"regex", @"find":it[@"find"]?:@"", @"replace":it[@"replace"]?:@""} mutableCopy]];
            }
            r[@"items"] = items;
            [nr addObject:r];
        }
        rules = nr; saveRules();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"追加" style:UIAlertActionStyleDefault handler:^(UIAlertAction*_){
        for (NSDictionary *o in arr) {
            NSMutableDictionary *r = [NSMutableDictionary new];
            r[@"url"] = o[@"url"]?:@""; r[@"name"] = o[@"name"]?:@"";
            r[@"dir"] = [o[@"direction"] isEqualToString:@"request"]?@"req":@"resp";
            NSMutableArray *items = [NSMutableArray new];
            for (NSDictionary *it in o[@"rules"]) {
                [items addObject:[@{@"matchType":it[@"matchType"]?:@"regex", @"find":it[@"find"]?:@"", @"replace":it[@"replace"]?:@""} mutableCopy]];
            }
            r[@"items"] = items;
            [rules addObject:r];
        }
        saveRules();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - 黑名单管理页
@interface BlacklistVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tv;
@end
@implementation BlacklistVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"黑名单";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clear)];
    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tv.dataSource = self; self.tv.delegate = self;
    [self.tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:self.tv];
}
- (void)clear { [blacklist removeAllObjects]; saveBlacklist(); [self.tv reloadData]; }
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return blacklist.count; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    c.textLabel.text = blacklist[ip.row]; return c;
}
- (void)tableView:(UITableView*)t commitEditingStyle:(UITableViewCellEditingStyle)e forRowAtIndexPath:(NSIndexPath*)ip {
    if (e == UITableViewCellEditingStyleDelete) { [blacklist removeObjectAtIndex:ip.row]; saveBlacklist(); [self.tv reloadData]; }
}
@end

#pragma mark - 主面板
@interface CapUI : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UILabel *statusLbl;
@end
@implementation CapUI
- (void)showPanel {
    if (_panel) { [_panel removeFromSuperview]; _panel = nil; return; }
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 50, w.frame.size.width, w.frame.size.height-100)];
    _panel.backgroundColor = [UIColor colorWithRed:0.96 green:0.96 blue:0.98 alpha:1.0];
    [w addSubview:_panel];
    UIView *navBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _panel.frame.size.width, 50)];
    navBar.backgroundColor = [UIColor whiteColor]; [_panel addSubview:navBar];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 26)];
    title.text = @"抓包"; title.font = [UIFont boldSystemFontOfSize:18]; [navBar addSubview:title];
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(_panel.frame.size.width-50, 12, 40, 26);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [navBar addSubview:closeBtn];
    _statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 56, 80, 20)];
    _statusLbl.font = [UIFont systemFontOfSize:13]; [_panel addSubview:_statusLbl];
    [self refreshStatus];
    NSArray *btns = @[@"开关", @"规则", @"清空", @"黑名单", @"编辑器"];
    NSArray *colors = @[[UIColor systemBlueColor], [UIColor systemPurpleColor], [UIColor systemRedColor], [UIColor systemOrangeColor], [UIColor systemTealColor]];
    for (int i = 0; i < 5; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(60+i*60, 54, 56, 24);
        [b setTitle:btns[i] forState:UIControlStateNormal];
        [b setTitleColor:colors[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:11]; b.tag = i;
        b.layer.cornerRadius = 12; b.layer.borderWidth = 1; b.layer.borderColor = [colors[i] CGColor];
        [b addTarget:self action:@selector(btn:) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:b];
    }
    _tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 84, _panel.frame.size.width, _panel.frame.size.height-84) style:UITableViewStylePlain];
    _tv.backgroundColor = [UIColor whiteColor]; _tv.dataSource = self; _tv.delegate = self;
    [_tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [_panel addSubview:_tv];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"CapNewReq" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [self.tv reloadData]; }];
}
- (void)refreshStatus {
    _statusLbl.text = enableCapture?@"●抓包中":@"○已关";
    _statusLbl.textColor = enableCapture?[UIColor systemGreenColor]:[UIColor grayColor];
}
- (void)close { [_panel removeFromSuperview]; _panel = nil; }
- (void)btn:(UIButton*)b {
    if (b.tag==0) { enableCapture=!enableCapture; [self refreshStatus]; }
    else if (b.tag==1) {
        RuleListVC *vc = [[RuleListVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:nav animated:YES completion:nil];
    }
    else if (b.tag==3) {
        BlacklistVC *vc = [[BlacklistVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:nav animated:YES completion:nil];
    }
    else if (b.tag==4) {
        RuleTextEditorVC *vc = [[RuleTextEditorVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:nav animated:YES completion:nil];
    }
    else { [reqs removeAllObjects]; [_tv reloadData]; }
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return reqs.count; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *r = reqs[ip.row];
    NSString *method = r[@"method"] ?: @"?";
    NSString *status = r[@"status"] ?: @"--";
    UIColor *sc = [status isEqualToString:@"200"] ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] init];
    if (r[@"rewritten"]) {
        [mas appendAttributedString:[[NSAttributedString alloc] initWithString:@"[重写] " attributes:@{NSForegroundColorAttributeName:[UIColor systemRedColor], NSFontAttributeName:[UIFont boldSystemFontOfSize:11]}]];
    }
    if (r[@"blacklisted"]) {
        [mas appendAttributedString:[[NSAttributedString alloc] initWithString:@"[黑名单] " attributes:@{NSForegroundColorAttributeName:[UIColor systemOrangeColor], NSFontAttributeName:[UIFont boldSystemFontOfSize:11]}]];
    }
    if ([r[@"src"] isEqualToString:@"Flutter-BoringSSL"]) {
        [mas appendAttributedString:[[NSAttributedString alloc] initWithString:@"[FL] " attributes:@{NSForegroundColorAttributeName:[UIColor systemPurpleColor], NSFontAttributeName:[UIFont boldSystemFontOfSize:11]}]];
    }
    [mas appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ ", method] attributes:@{NSForegroundColorAttributeName:[UIColor systemBlueColor], NSFontAttributeName:[UIFont boldSystemFontOfSize:12]}]];
    [mas appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ ", status] attributes:@{NSForegroundColorAttributeName:sc, NSFontAttributeName:[UIFont boldSystemFontOfSize:12]}]];
    [mas appendAttributedString:[[NSAttributedString alloc] initWithString:r[@"path"]?:@"" attributes:@{NSForegroundColorAttributeName:[UIColor darkTextColor], NSFontAttributeName:[UIFont systemFontOfSize:12]}]];
    c.textLabel.attributedText = mas; c.backgroundColor = [UIColor whiteColor]; return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    @try {
        ReqDetailVC *vc = [[ReqDetailVC alloc] init];
        vc.rec = reqs[ip.row];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *e) {}
}
- (UISwipeActionsConfiguration *)tableView:(UITableView*)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)ip {
    NSDictionary *r = reqs[ip.row];
    UIContextualAction *act = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"加到重写" handler:^(UIContextualAction *a, UIView *v, void(^done)(BOOL)) {
        NSMutableDictionary *rule = [NSMutableDictionary dictionaryWithDictionary:@{@"url":r[@"host"]?:@"", @"name":@"", @"dir":@"resp", @"items":[NSMutableArray new]}];
        [rules addObject:rule];
        RuleEditVC *vc = [[RuleEditVC alloc] init];
        vc.rule = rule;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:nav animated:YES completion:nil];
        done(YES);
    }];
    act.backgroundColor = [UIColor systemBlueColor];
    UIContextualAction *bl = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"黑名单" handler:^(UIContextualAction *a, UIView *v, void(^done)(BOOL)) {
        if (!blacklist) blacklist = [NSMutableArray new];
        NSString *host = r[@"host"] ?: r[@"url"];
        if (host.length && ![blacklist containsObject:host]) { [blacklist addObject:host]; saveBlacklist(); }
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[act, bl]];
}
- (void)btnTap { [self showPanel]; }
- (void)pan:(UIPanGestureRecognizer*)g {
    UIView *v=g.view; CGPoint p=[g translationInView:v.superview];
    CGRect f=v.frame; f.origin.x+=p.x; f.origin.y+=p.y; v.frame=f;
    [g setTranslation:CGPointZero inView:v.superview];
}
- (void)toggleBtn { self.btn.hidden = !self.btn.hidden; }
@end
static CapUI *capUI;

%ctor {
    if (!rules) { loadRules(); if (!rules) rules = [NSMutableArray new]; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        capUI = [CapUI new];
        capUI.btn = [UIButton buttonWithType:UIButtonTypeSystem];
        capUI.btn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width-56, 300, 44, 44);
        [capUI.btn setTitle:@"抓" forState:UIControlStateNormal];
        capUI.btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        capUI.btn.backgroundColor = [UIColor systemBlueColor];
        [capUI.btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        capUI.btn.layer.cornerRadius = 22; capUI.btn.layer.shadowOpacity = 0.3;
        [capUI.btn addTarget:capUI action:@selector(btnTap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:capUI action:@selector(pan:)];
        [capUI.btn addGestureRecognizer:pan];
        // 找当前真正的keyWindow（Scene架构）
        UIWindow *w = nil;
        for (UIWindowScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *win in s.windows) {
                    if (win.isKeyWindow) { w = win; break; }
                }
                if (!w && s.windows.count) w = s.windows.firstObject;
            }
            if (w) break;
        }
        if (!w) w = [UIApplication sharedApplication].keyWindow;
        if (w) [w addSubview:capUI.btn];
        UITapGestureRecognizer *tap3 = [[UITapGestureRecognizer alloc] initWithTarget:capUI action:@selector(toggleBtn)];
        tap3.numberOfTouchesRequired = 3;
        tap3.cancelsTouchesInView = NO;
        if (w) [w addGestureRecognizer:tap3];
        // 监听窗口切换，自动迁移按钮到新keyWindow
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            UIWindow *newWin = n.object;
            if (![newWin isKindOfClass:[UIWindow class]]) return;
            if (!capUI.btn) return;
            if (capUI.btn.window != newWin) {
                CGRect f = capUI.btn.frame;
                [newWin addSubview:capUI.btn];
                capUI.btn.frame = f;
            }
        }];
    });
}
