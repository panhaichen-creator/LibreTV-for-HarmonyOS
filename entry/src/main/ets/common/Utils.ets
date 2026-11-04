/**
 * 通用工具函数
 */

export class Utils {
  /** 毫秒 → mm:ss / h:mm:ss */
  static formatTime(ms: number): string {
    if (!isFinite(ms) || ms <= 0) {
      return '00:00';
    }
    const total = Math.floor(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return h > 0 ? h + ':' + pad(m) + ':' + pad(s) : pad(m) + ':' + pad(s);
  }

  static formatBytes(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB'];
    let v = bytes;
    let i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return (i === 0 ? v.toFixed(0) : v.toFixed(1)) + ' ' + units[i];
  }

  /** djb2 变体，生成稳定短 id */
  static stableId(input: string): string {
    let h = 5381;
    for (let i = 0; i < input.length; i++) {
      h = ((h << 5) + h + input.charCodeAt(i)) >>> 0;
    }
    return h.toString(36);
  }

  /** 归一化标题：去空白与常见标点，转小写（与 LibreTV normalizeTitle 对齐） */
  static normalizeTitle(s: string): string {
    if (!s) {
      return '';
    }
    return s.toLowerCase().replace(/[\s\u3000-\u303f\uff00-\uffef\u2000-\u206f!-\/:-@[-`{-~]/g, '');
  }

  /** 相对地址按基础 URL 解析为绝对地址 */
  static resolveUrl(base: string, rel: string): string {
    const r = rel.trim();
    if (r === '') {
      return r;
    }
    if (r.startsWith('http://') || r.startsWith('https://') || r.startsWith('fd://') || r.startsWith('file://')) {
      return r;
    }
    const protoEnd = base.indexOf('://');
    if (protoEnd < 0) {
      return r;
    }
    const proto = base.substring(0, protoEnd + 3);
    let rest = base.substring(protoEnd + 3);
    const qIdx = rest.indexOf('?');
    if (qIdx >= 0) {
      rest = rest.substring(0, qIdx);
    }
    const hIdx = rest.indexOf('#');
    if (hIdx >= 0) {
      rest = rest.substring(0, hIdx);
    }
    // 关键：目录只能从「path 部分」算，不能从整段 rest 算。
    // 老写法把 host 也算进了目录，于是 base=https://a.com/x/y.m3u8 + rel=z.m3u8
    // 会拼成 https://a.com/a.com/x/z.m3u8（主机名重复）→ 稳定 404。
    const hostEnd = rest.indexOf('/');
    const host = hostEnd >= 0 ? rest.substring(0, hostEnd) : rest;
    const pathPart = hostEnd >= 0 ? rest.substring(hostEnd) : '/';
    const slash = pathPart.lastIndexOf('/');
    const dir = slash >= 0 ? pathPart.substring(0, slash + 1) : '/';
    const combined = r.startsWith('/') ? r : dir + r;
    const parts = combined.split('/');
    const stack: string[] = [];
    for (const part of parts) {
      if (part === '' || part === '.') {
        continue;
      }
      if (part === '..') {
        stack.pop();
        continue;
      }
      stack.push(part);
    }
    return proto + host + '/' + stack.join('/');
  }

  static hostnameOf(url: string): string {
    try {
      const protoEnd = url.indexOf('://');
      let rest = protoEnd >= 0 ? url.substring(protoEnd + 3) : url;
      const slash = rest.indexOf('/');
      if (slash >= 0) {
        rest = rest.substring(0, slash);
      }
      return rest;
    } catch (e) {
      return url;
    }
  }

  static formatDate(ts: number): string {
    const d = new Date(ts);
    const pad = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 把 "第01集$url#第02集$url" 之类的字符串安全截断展示 */
  static clip(s: string, max: number): string {
    if (!s) {
      return '';
    }
    return s.length > max ? s.substring(0, max) + '…' : s;
  }

  /**
   * 清洗采集站返回的富文本简介。
   * 源站的 vod_content 常见 `<p>&nbsp;xxx</p>`、`<br/>`、`&#8220;` 等，
   * 直接显示就是一堆非中文符号（用户反馈的「占位符」）。
   * 处理顺序：<br> 换行 -> 块级标签转换行 -> 去剩余标签 -> 解实体 -> 收敛空白。
   */
  static stripHtml(raw: string): string {
    if (!raw) {
      return '';
    }
    let s = raw;
    // 块级/换行标签先转成真正的换行符，避免去掉标签后所有段落粘成一坨
    s = s.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<\/(p|div|li|tr|h[1-6])>/gi, '\n');
    // script/style 内容整体丢弃
    s = s.replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, '');
    // 剩余所有标签
    s = s.replace(/<[^>]*>/g, '');
    // HTML 实体解码（先处理数字实体与常见命名实体）
    s = Utils.decodeEntities(s);
    // 收敛空白：去掉行尾空格、压缩连续空行、整体 trim
    s = s.replace(/[ \t\u00a0]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    return s;
  }

  private static decodeEntities(s: string): string {
    const named: Map<string, string> = new Map<string, string>([
      ['nbsp', ' '],
      ['amp', '&'],
      ['lt', '<'],
      ['gt', '>'],
      ['quot', '"'],
      ['apos', "'"],
      ['ldquo', '“'],
      ['rdquo', '”'],
      ['lsquo', '‘'],
      ['rsquo', '’'],
      ['hellip', '…'],
      ['mdash', '—'],
      ['ndash', '–'],
      ['middot', '·'],
      ['laquo', '«'],
      ['raquo', '»']
    ]);
    // 命名实体
    let out = s.replace(/&([a-zA-Z]+);/g, (m: string, name: string): string => {
      const v = named.get(name.toLowerCase());
      return v !== undefined ? v : m;
    });
    // 数字实体 &#123; 与 &#x1F600;
    out = out.replace(/&#x([0-9a-fA-F]+);/g, (m: string, hex: string): string => {
      const code = parseInt(hex, 16);
      return isFinite(code) && code > 0 ? String.fromCharCode(code) : m;
    });
    out = out.replace(/&#(\d+);/g, (m: string, dec: string): string => {
      const code = parseInt(dec, 10);
      return isFinite(code) && code > 0 ? String.fromCharCode(code) : m;
    });
    return out;
  }

  /** 去除只剩标点/空白的内容；清洗后若无实质文字返回空串 */
  static hasMeaningfulText(s: string): boolean {
    if (!s) {
      return false;
    }
    // 去掉所有标点与空白后仍有内容才算有效
    return s.replace(/[\s\p{P}\p{S}]/gu, '').length > 0;
  }
}
