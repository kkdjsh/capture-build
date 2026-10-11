// Tweak.xm - 抓包插件 v12 (美化UI + 多规则重写)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL enableCapture = NO;
static NSMutableArray *reqs;
static const int MAX_REQS = 200;

// 重写规则: @{@"url":@"", @"find":@"", @"replace":@"", @"enabled":@YES}
static NSMutableArray *rules;

static void addReq(NSDictionary *r) {
    if (!reqs) reqs = [NSMutableArray new];
    [reqs addObject:r];
    if (reqs.count > MAX_REQS) [reqs removeObjectsInRange:NSMakeRange(0, reqs.count-MAX_REQS)];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CapNewReq" object:nil];
}

static NSString* applyRewrite(NSString *body, NSString *url) {
    if (!rules) return body;
    for (NSDictionary *rule in rules) {
        if (![rule[@"enabled"] boolValue]) continue;
        NSString *u = rule[@"url"];
        if (u.length && ![url containsString:u]) continue;
        NSString *f = rule[@"find"];
        if (f.length && [body containsString:f]) {
            body = [body stringByReplacingOccurrencesOfString:f withString:rule[@"replace"]?:@""];
        }
    }
    return body;
}

#pragma mark - NSURLProtocol

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
- (void)stopLoading { [[objc_getAssociatedObject(self, "task")] cancel]; }

- (void)URLSession:(NSURLSession *)dataSession dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSMutableDictionary *rec = objc_getAssociatedObject(self, "rec");
    rec[@"status"] = [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse*)response statusCode]];
    rec[@"respHeaders"] = [(NSHTTPURLResponse*)response allHeaderFields] ?: @{};
    objc_setAssociatedObject(self, "resp", response, OBJC_ASSOCIATION_RETAIN);
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)dataSession dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSMutableData *acc = objc_getAssociatedObject(self, "acc");
    if (acc && data) [acc appendData:data];
}
- (void)URLSession:(NSURLSession *)dataSession task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSMutableDictionary *rec = objc_getAssociatedObject(self, "rec");
    NSMutableData *acc = objc_getAssociatedObject(self, "acc");
    NSURLResponse *resp = objc_getAssociatedObject(self, "resp");
    NSData *finalData = acc;
    if (acc.length) {
        NSString *body = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding] ?: @"";
        body = applyRewrite(body, rec[@"url"]);
        finalData = [body dataUsingEncoding:NSUTF8StringEncoding];
        rec[@"respBody"] = body;
    }
    addReq(rec);
    if (resp && [resp isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse*)resp;
        NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:httpResp.allHeaderFields];
        headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)finalData.length];
        [headers removeObjectForKey:@"Content-Encoding"];
        NSHTTPURLResponse *newResp = [[NSHTTPURLResponse alloc] initWithURL:httpResp.URL statusCode:httpResp.statusCode HTTPVersion:@"HTTP/1.1" headerFields:headers];
        [self.client URLProtocol:self didReceiveResponse:newResp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    }
    if (finalData.length) [self.client URLProtocol:self didLoadData:finalData];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
}
@end

#pragma mark - Hook config
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

#pragma mark - 详情页
@interface ReqDetailVC : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) NSDictionary *rec;
@end
@implementation ReqDetailVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
    self.title = @"详情";
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:sv];
    CGFloat y = 20;
    // 基本信息
    UIFont *bold = [UIFont boldSystemFontOfSize:16];
    UIFont *norm = [UIFont systemFontOfSize:14];
    UIFont *mono = [UIFont fontWithName:@"Courier" size:12];
    NSArray *items = @[
        @[@"URL", self.rec[@"url"]],
        @[@"Method", self.rec[@"method"]],
        @[@"Status", self.rec[@"status"]],
        @[@"请求头", self.rec[@"reqHeaders"]],
        @[@"请求体", self.rec[@"reqBody"]],
        @[@"响应头", self.rec[@"respHeaders"]],
        @[@"响应体", self.rec[@"respBody"]],
    ];
    for (NSArray *item in items) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, self.view.frame.size.width-32, 22)];
        lbl.text = item[0]; lbl.font = bold; lbl.textColor = [UIColor darkTextColor];
        [sv addSubview:lbl]; y += 26;
        UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(16, y, self.view.frame.size.width-32, 0)];
        NSString *v = [item[1] isKindOfClass:[NSDictionary class]] ? [(NSDictionary*)item[1] description] : (item[1]?:@"(空)");
        val.text = v; val.font = mono; val.textColor = [UIColor darkGrayColor];
        val.numberOfLines = 0;
        CGSize sz = [val sizeThatFits:CGSizeMake(self.view.frame.size.width-32, CGFLOAT_MAX)];
        val.frame = CGRectMake(16, y, sz.width, sz.height);
        [sv addSubview:val]; y += sz.height + 20;
    }
    sv.contentSize = CGSizeMake(self.view.frame.size.width, y+40);
}
@end

#pragma mark - 重写规则编辑页
@interface RuleEditVC : UIViewController
@property (nonatomic, strong) NSMutableDictionary *rule;
@property (nonatomic, copy) void(^onSave)(void);
@property (nonatomic, copy) void(^onChange)(void);
@end
@implementation RuleEditVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"重写规则";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    CGFloat y = 100;
    NSArray *fields = @[@"URL包含(空=全部)", @"查找", @"替换为"];
    NSArray *keys = @[@"url", @"find", @"replace"];
    for (int i = 0; i < 3; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 200, 20)];
        l.text = fields[i]; l.font = [UIFont systemFontOfSize:14]; [self.view addSubview:l]; y += 26;
        UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(16, y, self.view.frame.size.width-32, 40)];
        f.borderStyle = UITextBorderStyleRoundedRect; f.font = [UIFont systemFontOfSize:14];
        f.text = self.rule[keys[i]]; f.tag = 100+i;
        [self.view addSubview:f]; y += 50;
    }
}
- (void)save {
    for (int i = 0; i < 3; i++) {
        UITextField *f = (UITextField*)[self.view viewWithTag:100+i];
        self.rule[@[@"url",@"find",@"replace"][i]] = f.text ?: @"";
    }
    self.rule[@"enabled"] = @YES;
    [self.navigationController popViewControllerAnimated:YES];
    if (self.onSave) self.onSave();
}
@end

#pragma mark - 规则列表页
@interface RuleListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, copy) void(^onChange)(void);
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
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:@{@"url":@"",@"find":@"",@"replace":@"",@"enabled":@YES}];
    [rules addObject:r];
    RuleEditVC *vc = [[RuleEditVC alloc] init];
    vc.rule = r; vc.onChange = self.onChange;
    [self.navigationController pushViewController:vc animated:YES];
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return rules.count; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *r = rules[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@ -> %@\nURL: %@", r[@"find"], r[@"replace"], [(NSString*)r[@"url"] length]?r[@"url"]:@"全部"];
    c.textLabel.numberOfLines = 2; c.textLabel.font = [UIFont systemFontOfSize:12];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    RuleEditVC *vc = [[RuleEditVC alloc] init];
    vc.rule = rules[ip.row]; vc.onChange = self.onChange;
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

    // 导航栏
    UIView *navBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _panel.frame.size.width, 50)];
    navBar.backgroundColor = [UIColor whiteColor];
    [_panel addSubview:navBar];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 26)];
    title.text = @"抓包"; title.font = [UIFont boldSystemFontOfSize:18]; [navBar addSubview:title];
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(_panel.frame.size.width-50, 12, 40, 26);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [navBar addSubview:closeBtn];

    // 状态栏
    _statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 56, 80, 20)];
    _statusLbl.font = [UIFont systemFontOfSize:13]; [_panel addSubview:_statusLbl];
    [self refreshStatus];

    // 按钮
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

    // 列表
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
        vc.onChange = ^{};
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
    c.textLabel.attributedText = mas;
    c.backgroundColor = [UIColor whiteColor]; return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    ReqDetailVC *vc = [[ReqDetailVC alloc] init];
    vc.rec = reqs[ip.row];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:nav animated:YES completion:nil];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView*)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)ip {
    NSDictionary *r = reqs[ip.row];
    UIContextualAction *act = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"加到重写" handler:^(UIContextualAction *a, UIView *v, void(^done)(BOOL)) {
        NSMutableDictionary *rule = [NSMutableDictionary dictionaryWithDictionary:@{@"url":r[@"host"]?:@"", @"find":@"", @"replace":@"", @"enabled":@YES}];
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
        capUI.btn.layer.cornerRadius = 22;
        capUI.btn.layer.shadowOpacity = 0.3;
        [capUI.btn addTarget:capUI action:@selector(btnTap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:capUI action:@selector(pan:)];
        [capUI.btn addGestureRecognizer:pan];
        [w addSubview:capUI.btn];
    });
}
