// Tweak.xm - 抓包插件 v13
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL enableCapture = NO;
static NSMutableArray *reqs;
static const int MAX_REQS = 200;
// 规则: @{@"url":@"", @"dir":@"resp", @"find":@"", @"replace":@"", @"enabled":@YES}
static NSMutableArray *rules;

static void addReq(NSDictionary *r) {
    if (!reqs) reqs = [NSMutableArray new];
    [reqs addObject:r];
    if (reqs.count > MAX_REQS) [reqs removeObjectsInRange:NSMakeRange(0, reqs.count-MAX_REQS)];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CapNewReq" object:nil];
}

static NSString* applyRules(NSString *body, NSString *url, NSString *dir) {
    if (!rules) return body;
    for (NSDictionary *rule in rules) {
        if (![rule[@"enabled"] boolValue]) continue;
        NSString *d = rule[@"dir"] ?: @"resp";
        if (![d isEqualToString:dir]) continue;
        NSString *u = rule[@"url"];
        if (u.length && ![url containsString:u]) continue;
        NSString *f = rule[@"find"];
        if (f.length && [body containsString:f]) {
            body = [body stringByReplacingOccurrencesOfString:f withString:rule[@"replace"]?:@""];
        }
    }
    return body;
}

#pragma mark - Protocol

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
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:@"" forHTTPHeaderField:@"Accept-Encoding"];

    // 请求体重写
    if (req.HTTPBody) {
        NSString *body = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
        body = applyRules(body, req.URL.absoluteString, @"req");
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

    NSURLSession *s = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:self delegateQueue:nil];
    NSURLSessionDataTask *t = [s dataTaskWithRequest:req];
    objc_setAssociatedObject(self, "task", t, OBJC_ASSOCIATION_RETAIN);
    [t resume];
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
        body = applyRules(body, rec[@"url"], @"resp");
        finalData = [body dataUsingEncoding:NSUTF8StringEncoding];
        rec[@"respBody"] = body;
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
    ch(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
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
- (NSArray *)protocolClasses {
    NSArray *arr = %orig;
    NSMutableArray *mut = [NSMutableArray arrayWithArray:arr ?: @[]];
    if (![mut containsObject:[CapProtocol class]]) [mut insertObject:[CapProtocol class] atIndex:0];
    return mut;
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

#pragma mark - 详情页(简化，防止闪退)
@interface ReqDetailVC : UIViewController
@property (nonatomic, strong) NSDictionary *rec;
@end
@implementation ReqDetailVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"请求详情";
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:sv];
    CGFloat y = 80;
    UIFont *mono = [UIFont fontWithName:@"Courier" size:11];
    NSArray *items = @[@"URL", @"Method", @"Status", @"请求头", @"请求体", @"响应头", @"响应体"];
    NSArray *keys = @[@"url", @"method", @"status", @"reqHeaders", @"reqBody", @"respHeaders", @"respBody"];
    for (int i = 0; i < items.count; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 300, 20)];
        l.text = items[i]; l.font = [UIFont boldSystemFontOfSize:14]; [sv addSubview:l]; y += 24;
        id v = self.rec[keys[i]];
        NSString *s = [v isKindOfClass:[NSDictionary class]] ? [(NSDictionary*)v description] : (v ?: @"(空)");
        UILabel *v2 = [[UILabel alloc] initWithFrame:CGRectMake(16, y, self.view.frame.size.width-32, 0)];
        v2.text = s; v2.font = mono; v2.numberOfLines = 0; v2.textColor = [UIColor darkGrayColor];
        CGSize sz = [v2 sizeThatFits:CGSizeMake(self.view.frame.size.width-32, 10000)];
        v2.frame = CGRectMake(16, y, sz.width, sz.height);
        [sv addSubview:v2]; y += sz.height + 16;
    }
    sv.contentSize = CGSizeMake(self.view.frame.size.width, y+40);
}
@end

#pragma mark - 规则编辑页
@interface RuleEditVC : UIViewController
@property (nonatomic, strong) NSMutableDictionary *rule;
@property (nonatomic, copy) void(^onSave)(void);
@end
@implementation RuleEditVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.title = @"编辑规则";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    CGFloat y = 80;
    // 方向选择
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"响应体", @"请求体"]];
    seg.frame = CGRectMake(16, y, self.view.frame.size.width-32, 30);
    seg.selectedSegmentIndex = [self.rule[@"dir"] isEqualToString:@"req"] ? 1 : 0;
    seg.tag = 99; [self.view addSubview:seg]; y += 50;
    NSArray *fields = @[@"URL包含(空=全部)", @"查找", @"替换为"];
    NSArray *keys = @[@"url", @"find", @"replace"];
    for (int i = 0; i < 3; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 200, 20)];
        l.text = fields[i]; [self.view addSubview:l]; y += 26;
        UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(16, y, self.view.frame.size.width-32, 40)];
        f.borderStyle = UITextBorderStyleRoundedRect; f.font = [UIFont systemFontOfSize:14];
        f.text = self.rule[keys[i]]; f.tag = 100+i;
        [self.view addSubview:f]; y += 50;
    }
}
- (void)save {
    UISegmentedControl *seg = (UISegmentedControl*)[self.view viewWithTag:99];
    self.rule[@"dir"] = seg.selectedSegmentIndex == 1 ? @"req" : @"resp";
    for (int i = 0; i < 3; i++) {
        UITextField *f = (UITextField*)[self.view viewWithTag:100+i];
        self.rule[@[@"url",@"find",@"replace"][i]] = f.text ?: @"";
    }
    self.rule[@"enabled"] = @YES;
    [self.navigationController popViewControllerAnimated:YES];
    if (self.onSave) self.onSave();
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
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:@{@"url":@"",@"find":@"",@"replace":@"",@"dir":@"resp",@"enabled":@YES}];
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
    c.textLabel.text = [NSString stringWithFormat:@"[%@] %@ -> %@\nURL: %@", dir, r[@"find"], r[@"replace"], [(NSString*)r[@"url"] length]?r[@"url"]:@"全部"];
    c.textLabel.numberOfLines = 2; c.textLabel.font = [UIFont systemFontOfSize:12];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    RuleEditVC *vc = [[RuleEditVC alloc] init];
    vc.rule = rules[ip.row];
    [self.navigationController pushViewController:vc animated:YES];
}
- (void)tableView:(UITableView*)t commitEditingStyle:(UITableViewCellEditingStyle)e forRowAtIndexPath:(NSIndexPath*)ip {
    if (e == UITableViewCellEditingStyleDelete) { [rules removeObjectAtIndex:ip.row]; [self.tv reloadData]; }
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
    NSArray *btns = @[@"开关", @"规则", @"清空"];
    NSArray *colors = @[[UIColor systemBlueColor], [UIColor systemPurpleColor], [UIColor systemRedColor]];
    for (int i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(100+i*70, 54, 60, 24);
        [b setTitle:btns[i] forState:UIControlStateNormal];
        [b setTitleColor:colors[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13]; b.tag = i;
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
    } else { [reqs removeAllObjects]; [_tv reloadData]; }
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return reqs.count; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *r = reqs[ip.row];
    NSString *method = r[@"method"] ?: @"?";
    NSString *status = r[@"status"] ?: @"--";
    UIColor *sc = [status isEqualToString:@"200"] ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] init];
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
        NSMutableDictionary *rule = [NSMutableDictionary dictionaryWithDictionary:@{@"url":r[@"host"]?:@"", @"find":@"", @"replace":@"", @"dir":@"resp", @"enabled":@YES}];
        [rules addObject:rule];
        RuleEditVC *vc = [[RuleEditVC alloc] init];
        vc.rule = rule;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:nav animated:YES completion:nil];
        done(YES);
    }];
    act.backgroundColor = [UIColor systemBlueColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[act]];
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
    if (!rules) rules = [NSMutableArray new];
    dispatch_async(dispatch_get_main_queue(), ^{
        capUI = [CapUI new];
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        capUI.btn = [UIButton buttonWithType:UIButtonTypeSystem];
        capUI.btn.frame = CGRectMake(w.frame.size.width-56, 300, 44, 44);
        [capUI.btn setTitle:@"抓" forState:UIControlStateNormal];
        capUI.btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        capUI.btn.backgroundColor = [UIColor systemBlueColor];
        [capUI.btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        capUI.btn.layer.cornerRadius = 22; capUI.btn.layer.shadowOpacity = 0.3;
        [capUI.btn addTarget:capUI action:@selector(btnTap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:capUI action:@selector(pan:)];
        [capUI.btn addGestureRecognizer:pan];
        [w addSubview:capUI.btn];
    });
}
