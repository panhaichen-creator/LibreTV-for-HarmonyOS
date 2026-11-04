/**
 * 影片分享链接：编解码 + 「被链接唤起」时的待处理中转。
 *
 * 链接形如：
 *   libretv://play?src=<源 key>&id=<vodId>&ep=<集下标>&t=<片名>&n=<集名>&p=<封面地址>
 * 每个值都经过 encodeURIComponent，片名里的 & / 空格 / 中文都不会截断参数。
 *
 * 为什么用自定义 scheme，而不是 https 的 App Linking：
 *   App Linking 要求在自有域名根目录放 assetlinks 校验文件（服务器侧），
 *   本项目没有后台，无法通过校验；而自定义 scheme 在「对方也装了本 APP」时
 *   由系统直接拉起目标应用，正好是这里要的场景。
 *   将来有了域名，把 SCHEME 换成 https、再补一条 uris 声明即可平滑迁移。
 */

/** 一条分享链接里携带的全部信息：够播放页直接起播 */
export interface ShareTarget {
  sourceKey: string;
  vodId: string;
  episode: number;
  episodeName: string;
  title: string;
  pic: string;
}

export class ShareLink {
  static readonly SCHEME: string = 'libretv';
  static readonly HOST: string = 'play';

  /**
   * 分享落地页站点根（例：'https://share.example.com'，指向 share/landing.html）。
   *
   * 留空 = 直接分享自定义 scheme（libretv://）：
   *   ✅ 浏览器 / 短信 / 备忘录 / 系统分享里点一下就能拉起 APP；
   *   ❌ 微信里既没有封面卡片，也点不动（微信只放行它白名单里的 scheme，且
   *      内置浏览器禁止页面跳第三方 scheme —— 这就是「必须用浏览器打开」的原因）。
   *
   * 填上 https 域名后，分享出去的是 https://<base>/p?...：
   *   微信按落地页的 Open Graph 标签生成带封面的卡片，页面里负责
   *   「非微信环境自动跳 APP / 微信环境引导右上角用浏览器打开」。
   */
  static readonly WEB_BASE: string = '';

  /** 拼一条分享链接 */
  static build(t: ShareTarget): string {
    const seg: string[] = [];
    seg.push('src=' + encodeURIComponent(t.sourceKey));
    seg.push('id=' + encodeURIComponent(t.vodId));
    seg.push('ep=' + (t.episode > 0 ? t.episode : 0));
    if (t.title !== '') {
      seg.push('t=' + encodeURIComponent(t.title));
    }
    if (t.episodeName !== '') {
      seg.push('n=' + encodeURIComponent(t.episodeName));
    }
    if (t.pic !== '') {
      seg.push('p=' + encodeURIComponent(t.pic));
    }
    const query: string = seg.join('&');
    if (ShareLink.WEB_BASE !== '') {
      return ShareLink.WEB_BASE + '/p?' + query;
    }
    return ShareLink.SCHEME + '://' + ShareLink.HOST + '?' + query;
  }

  /** 解析；不是本 APP 的链接（或被改坏）返回 null */
  static parse(uri: string): ShareTarget | null {
    if (uri === '') {
      return null;
    }
    // 两种入口都要认：自定义 scheme，以及落地页的 https 链接
    const low: string = uri.toLowerCase();
    const prefix: string = ShareLink.SCHEME + '://' + ShareLink.HOST;
    const isScheme: boolean = low.startsWith(prefix);
    const isWeb: boolean = (low.startsWith('http://') || low.startsWith('https://'))
      && low.indexOf('/p?') >= 0;
    if (!isScheme && !isWeb) {
      return null;
    }
    const q: number = uri.indexOf('?');
    let query: string = q >= 0 ? uri.substring(q + 1) : '';
    // 有的渠道（短信、便签）会在末尾追加 #fragment，一并切掉
    const hash: number = query.indexOf('#');
    if (hash >= 0) {
      query = query.substring(0, hash);
    }
    const map: Map<string, string> = new Map();
    for (const seg of query.split('&')) {
      const eq: number = seg.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      map.set(seg.substring(0, eq), ShareLink.dec(seg.substring(eq + 1)));
    }
    const src: string | undefined = map.get('src');
    const id: string | undefined = map.get('id');
    if (src === undefined || id === undefined || src === '' || id === '') {
      return null;
    }
    let ep: number = 0;
    const epRaw: string | undefined = map.get('ep');
    if (epRaw !== undefined) {
      const n: number = Number.parseInt(epRaw, 10);
      if (!Number.isNaN(n) && n > 0) {
        ep = n;
      }
    }
    const t: string | undefined = map.get('t');
    const n2: string | undefined = map.get('n');
    const p: string | undefined = map.get('p');
    const target: ShareTarget = {
      sourceKey: src,
      vodId: id,
      episode: ep,
      episodeName: n2 !== undefined ? n2 : '',
      title: t !== undefined ? t : '',
      pic: p !== undefined ? p : ''
    };
    return target;
  }

  private static dec(v: string): string {
    try {
      return decodeURIComponent(v);
    } catch (e) {
      // 手改坏的百分号编码：按原样返回，别让整个链接失效
      return v;
    }
  }
}

export type DeepLinkHandler = (link: string) => void;

/**
 * 外部链接的中转站（单槽位）。
 *
 * 冷启动时序：EntryAbility.onCreate 拿到 want.uri 时，IndexPage 还没挂载，
 * 没人能接这条链接 —— 先存进 pending，等页面 aboutToAppear 调 attach() 时补发。
 * 热启动（应用已在后台）走 onNewWant，此时 handler 已在，直接回调。
 *
 * 只留一个槽位就够：同一时刻只有一个可见的主页面。
 * 回调必须是外部传进来的箭头函数（成员方法当回调会丢 this）。
 */
export class DeepLink {
  private static pending: string = '';
  private static handler: DeepLinkHandler | null = null;

  /** EntryAbility 收到 viewData 时调用 */
  static push(uri: string): void {
    if (uri === '') {
      return;
    }
    if (DeepLink.handler !== null) {
      DeepLink.handler(uri);
      return;
    }
    DeepLink.pending = uri;
  }

  /** 主页面挂载/重新可见时接管，并补发此前积压的链接 */
  static attach(h: DeepLinkHandler): void {
    DeepLink.handler = h;
    const p: string = DeepLink.pending;
    DeepLink.pending = '';
    if (p !== '') {
      h(p);
    }
  }

  static detach(): void {
    DeepLink.handler = null;
  }

  /** 当前是否有待处理链接（调试用） */
  static hasPending(): boolean {
    return DeepLink.pending !== '';
  }
}
