// Tweak.xm - 抓包插件 v8 (hook config + NSURLProtocol)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL enableCapture = NO;
static NSMutableArray *reqs;
static const int MAX_REQS = 200;
static NSString *rewriteFind = @"";
static NSString *rewriteRepl = @"";

static void addReq(NSDictionary *r) {
    if (!reqs) reqs = [NSMutableArray new];
    [reqs addObject:r];
    if (reqs.count > MAX_REQS) [reqs removeObjectsInRange:NSMakeRange(0, reqs.count-MAX_REQS)];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CapNewReq" object:nil];
}

#pragma mark - 自定义 NSURLProtocol

@interface CapProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@end

@implementation CapProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!enableCapture) return NO;
    if ([NSURLProtocol propertyForKey:@"capHandled" inRequest:request]) return NO;
    return [request.URL.scheme isEqualToString:@"http"] || [request.URL.scheme isEqualToString:@"https"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"capHandled" inRequest:req];

    NSMutableDictionary *rec = [NSMutableDictionary new];
    rec[@"method"] = req.HTTPMethod ?: @"GET";
    rec[@"url"] = req.URL.absoluteString;
    rec[@"reqHeaders"] = req.allHTTPHeaderFields ?: @{};
    if (req.HTTPBody) rec[@"reqBody"] = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
    objc_setAssociatedObject(self, "rec", rec, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, "acc", [NSMutableData new], OBJC_ASSOCIATION_RETAIN);

    NSURLSession *s = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:self delegateQueue:nil];
    NSURLSessionDataTask *t = [s dataTaskWithRequest:req];
    objc_setAssociatedObject(self, "task", t, OBJC_ASSOCIATION_RETAIN);
    [t resume];
}
- (void)stopLoading {
    NSURLSessionDataTask *t = objc_getAssociatedObject(self, "task");
    [t cancel];
}
- (void)URLSession:(NSURLSession *)dataSession dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSMutableDictionary *rec = objc_getAssociatedObject(self, "rec");
    rec[@"status"] = [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse*)response statusCode]];
    rec[@"respHeaders"] = [(NSHTTPURLResponse*)response allHeaderFields] ?: @{};
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)dataSession dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSMutableData *acc = objc_getAssociatedObject(self, "acc");
    if (acc) [acc appendData:data];
    [self.client URLProtocol:self didLoadData:data];
}
- (void)URLSession:(NSURLSession *)dataSession task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSMutableDictionary *rec = objc_getAssociatedObject(self, "rec");
    NSMutableData *acc = objc_getAssociatedObject(self, "acc");
    if (acc.length) {
        NSString *body = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding] ?: @"";
        if (rewriteFind.length && [body containsString:rewriteFind]) {
            body = [body stringByReplacingOccurrencesOfString:rewriteFind withString:rewriteRepl];
        }
        rec[@"respBody"] = body;
    }
    addReq(rec);
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
}
@end

#pragma mark - Hook NSURLSessionConfiguration 注入 Protocol

%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    if (enableCapture) {
        NSMutableArray *arr = [NSMutableArray arrayWithArray:c.protocolClasses ?: @[]];
        BOOL has = NO;
        for (Class cls in arr) { if (cls == [CapProtocol class]) has = YES; }
        if (!has) [arr insertObject:[CapProtocol class] atIndex:0];
        c.protocolClasses = arr;
    }
    return c;
}
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    if (enableCapture) {
        NSMutableArray *arr = [NSMutableArray arrayWithArray:c.protocolClasses ?: @[]];
        BOOL has = NO;
        for (Class cls in arr) { if (cls == [CapProtocol class]) has = YES; }
        if (!has) [arr insertObject:[CapProtocol class] atIndex:0];
        c.protocolClasses = arr;
    }
    return c;
}
- (NSArray *)protocolClasses {
    NSArray *arr = %orig;
    if (enableCapture) {
        NSMutableArray *mut = [NSMutableArray arrayWithArray:arr ?: @[]];
        BOOL has = NO;
        for (Class cls in mut) { if (cls == [CapProtocol class]) has = YES; }
        if (!has) [mut insertObject:[CapProtocol class] atIndex:0];
        arr = mut;
    }
    return arr;
}
%end

// SSL Pinning 绕过
%hook NSObject
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else %orig;
}
%end

#pragma mark - UI

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
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    [w addSubview:_panel];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 200, 24)];
    title.text = @"抓包面板"; title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:18]; [_panel addSubview:title];
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(w.frame.size.width-50, 10, 40, 24);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:closeBtn];
    _statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 38, 100, 22)];
    _statusLbl.font = [UIFont systemFontOfSize:13]; [_panel addSubview:_statusLbl];
    [self refreshStatus];
    NSArray *btns = @[@"开关", @"重写", @"清空"];
    for (int i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(110+i*60, 38, 55, 22);
        [b setTitle:btns[i] forState:UIControlStateNormal];
        [b setTitleColor:@[[UIColor yellowColor],[UIColor orangeColor],[UIColor redColor]][i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12]; b.tag = i;
        [b addTarget:self action:@selector(btn:) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:b];
    }
    _tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 68, w.frame.size.width, _panel.frame.size.height-68) style:UITableViewStylePlain];
    _tv.backgroundColor = [UIColor blackColor]; _tv.dataSource = self; _tv.delegate = self;
    [_tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [_panel addSubview:_tv];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"CapNewReq" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [self.tv reloadData]; }];
}
- (void)refreshStatus { _statusLbl.text = enableCapture?@"●抓包中":@"○已关"; _statusLbl.textColor = enableCapture?[UIColor greenColor]:[UIColor grayColor]; }
- (void)close { [_panel removeFromSuperview]; _panel = nil; }
- (void)btn:(UIButton*)b {
    if (b.tag==0) { enableCapture=!enableCapture; [self refreshStatus]; }
    else if (b.tag==1) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"响应重写" message:@"查找(空=关)" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"查找";f.text=rewriteFind;}];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"替换为";f.text=rewriteRepl;}];
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction*_){rewriteFind=a.textFields[0].text?:@"";rewriteRepl=a.textFields[1].text?:@"";}]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:a animated:YES completion:nil];
    } else { [reqs removeAllObjects]; [_tv reloadData]; }
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return reqs.count; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *r = reqs[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"[%@] %@ %@", r[@"method"]?:@"?", r[@"status"]?:@"", r[@"url"]?:@""];
    c.textLabel.textColor = [UIColor greenColor]; c.textLabel.font = [UIFont fontWithName:@"Courier" size:9];
    c.backgroundColor = [UIColor blackColor]; return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    NSDictionary *r = reqs[ip.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:r[@"url"] message:nil preferredStyle:UIAlertControllerStyleAlert];
    NSMutableString *m = [NSMutableString new];
    [m appendFormat:@"Method: %@\nStatus: %@\n\n", r[@"method"], r[@"status"]];
    if (r[@"reqHeaders"]) [m appendFormat:@"ReqH: %@\n\n", r[@"reqHeaders"]];
    if (r[@"reqBody"]) [m appendFormat:@"ReqB: %@\n\n", r[@"reqBody"]];
    if (r[@"respHeaders"]) [m appendFormat:@"RespH: %@\n\n", r[@"respHeaders"]];
    if (r[@"respBody"]) [m appendFormat:@"RespB: %@", r[@"respBody"]];
    a.message = m.length>4000?[m substringToIndex:4000]:m;
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)btnTap { [self showPanel]; }
- (void)pan:(UIPanGestureRecognizer*)g {
    UIView *v=g.view; CGPoint p=[g translationInView:v.superview];
    CGRect f=v.frame; f.origin.x+=p.x; f.origin.y+=p.y; v.frame=f;
    [g setTranslation:CGPointZero inView:v.superview];
}
@end
static CapUI *capUI;

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        capUI = [CapUI new];
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        capUI.btn = [UIButton buttonWithType:UIButtonTypeSystem];
        capUI.btn.frame = CGRectMake(w.frame.size.width-56, 300, 44, 44);
        [capUI.btn setTitle:@"抓包" forState:UIControlStateNormal];
        capUI.btn.titleLabel.font = [UIFont systemFontOfSize:11];
        capUI.btn.backgroundColor = [UIColor colorWithRed:0.9 green:0.5 blue:0.2 alpha:0.9];
        capUI.btn.layer.cornerRadius = 22;
        [capUI.btn addTarget:capUI action:@selector(btnTap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:capUI action:@selector(pan:)];
        [capUI.btn addGestureRecognizer:pan];
        [w addSubview:capUI.btn];
    });
}
