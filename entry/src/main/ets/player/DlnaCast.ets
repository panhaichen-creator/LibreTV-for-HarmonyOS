/**
 * DLNA 投屏：SSDP 发现局域网内的 MediaRenderer（电视/盒子），SOAP 控制 AVTransport。
 *
 * 为什么自研这套而不是只靠系统投播（AVCastPicker）：
 * 系统投播的设备发现依赖 Cast+ 生态（华为智慧屏等），普通智能电视/
 * 盒子常常搜不到；DLNA 是几乎所有电视都内置的通用互操作协议。
 *
 * 关键性质：SetAVTransportURI 只是把播放地址「告诉」电视，之后电视自己
 * 拉流 —— 与本 App 是否存活完全解耦，退出应用、锁屏都不影响电视继续播放。
 */

import { socket, http } from '@kit.NetworkKit';

/** 一台可投屏的 DLNA 渲染设备 */
export class DlnaDevice {
  /** 设备显示名（设备描述里的 friendlyName） */
  name: string;
  /** 设备描述文档地址（SSDP 的 LOCATION，仅发现阶段用） */
  location: string;
  /** AVTransport 服务的 SOAP 控制地址（已拼成绝对 URL） */
  controlUrl: string;
  /** RenderingControl 服务的 SOAP 控制地址（远程调电视音量用；空串 = 设备不带此服务） */
  volumeUrl: string;

  constructor(name: string, location: string, controlUrl: string, volumeUrl: string) {
    this.name = name;
    this.location = location;
    this.controlUrl = controlUrl;
    this.volumeUrl = volumeUrl;
  }
}

/** GetPositionInfo 的解析结果（单位：秒） */
export class DlnaPosition {
  positionSec: number;
  durationSec: number;

  constructor(positionSec: number, durationSec: number) {
    this.positionSec = positionSec;
    this.durationSec = durationSec;
  }
}

/** SSDP 发现：组播 M-SEARCH → 收 LOCATION → 拉设备描述 → 解析 AVTransport */
export class DlnaDiscovery {
  /**
   * 搜索局域网 DLNA 渲染设备。
   * 向 SSDP 组播地址 239.255.255.250:1900 发 M-SEARCH（同时兜底发一份
   * 广播，个别路由器禁组播），支持 UPnP 的电视会回 200 OK 并带 LOCATION
   * 指向设备描述 XML；再逐台拉描述解析出 friendlyName 和控制地址。
   * 只保留带 AVTransport 服务的设备（可接收视频推流的才有意义）。
   */
  static async scan(timeoutMs: number): Promise<DlnaDevice[]> {
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    const locations: string[] = [];
    const seen: Record<string, boolean> = {};
    try {
      // 端口随机挑一个：SSDP 应答是单播回给「发出端口」的，不用 1900
      const port: number = 20000 + Math.floor(Math.random() * 30000);
      const addr: socket.NetAddress = { address: '0.0.0.0', port: port };
      await udp.bind(addr);
      udp.on('message', (info: socket.SocketMessageInfo) => {
        const text: string = latinDecode(info.message);
        if (text.indexOf('HTTP/1.1 200') < 0 && text.indexOf('HTTP/1.0 200') < 0) {
          return;
        }
        const m = text.match(/LOCATION:\s*(\S+)/i);
        if (m === null || m.length < 2) {
          return;
        }
        const loc: string = m[1];
        // 同一台设备会对多个 M-SEARCH 各回一次，按 LOCATION 去重
        if (loc.startsWith('http') && seen[loc] !== true) {
          seen[loc] = true;
          locations.push(loc);
        }
      });
      await DlnaDiscovery.sendSearch(udp);
      await DlnaDiscovery.sleep(400);
      // UDP 不可靠，设备也可能漏收：隔 400ms 再搜一轮
      await DlnaDiscovery.sendSearch(udp);
      await DlnaDiscovery.sleep(timeoutMs);
      try {
        await udp.close();
      } catch (e) {
        // ignore
      }
    } catch (e) {
      // 绑定失败（端口冲突等）：返回空列表，上层照常展示「未找到设备」
      return [];
    }
    // 逐台拉设备描述（并发）。上限 16：家里正常也就几台，
    // 上限只是防止连了 NAS 的极端网络把面板拖成几十秒
    const capped: string[] = locations.length > 16 ? locations.slice(0, 16) : locations;
    const tasks: Promise<DlnaDevice | null>[] = [];
    for (const loc of capped) {
      tasks.push(DlnaDiscovery.fetchDevice(loc));
    }
    const results: (DlnaDevice | null)[] = await Promise.all(tasks);
    const devices: DlnaDevice[] = [];
    for (const dev of results) {
      if (dev !== null) {
        devices.push(dev);
      }
    }
    return devices;
  }

  private static async sendSearch(udp: socket.UDPSocket): Promise<void> {
    // 两种 ST：定向 AVTransport（响应干净）+ ssdp:all（部分电视只回全量搜索）
    const targets: string[] = ['urn:schemas-upnp-org:service:AVTransport:1', 'ssdp:all'];
    const hosts: string[] = ['239.255.255.250', '255.255.255.255'];
    for (const st of targets) {
      const msg: string = 'M-SEARCH * HTTP/1.1\r\n' +
        'HOST: 239.255.255.250:1900\r\n' +
        'MAN: "ssdp:discover"\r\n' +
        'MX: 3\r\n' +
        'ST: ' + st + '\r\n\r\n';
      const data: Uint8Array = encodeLatin(msg);
      for (const host of hosts) {
        // UDPSendOptions.address 是 NetAddress 结构（主机+端口在一起）
        const dest: socket.NetAddress = { address: host, port: 1900 };
        const opt: socket.UDPSendOptions = { data: data.buffer, address: dest };
        try {
          await udp.send(opt);
        } catch (e) {
          // 单个目标发不出去不致命（比如路由器禁广播）
        }
      }
    }
  }

  /** 拉取并解析设备描述 XML：必须含 AVTransport 服务才算可投屏设备 */
  private static async fetchDevice(location: string): Promise<DlnaDevice | null> {
    const client: http.HttpRequest = http.createHttp();
    let xml: string = '';
    try {
      const header: Record<string, string> = {
        'User-Agent': 'LibreTV/1.0 UPnP/1.0',
        'Accept': '*/*'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 3000,
        readTimeout: 3000,
        expectDataType: http.HttpDataType.STRING
      };
      const resp = await client.request(location, options);
      if (typeof resp.result === 'string') {
        xml = resp.result;
      }
    } catch (e) {
      return null;
    } finally {
      client.destroy();
    }
    if (xml === '') {
      return null;
    }
    const services = xml.match(/<service>[\s\S]*?<\/service>/gi);
    if (services === null) {
      return null;
    }
    let controlUrl: string = '';
    let volumeUrl: string = '';
    for (const svc of services) {
      if (controlUrl === '' && svc.indexOf('urn:schemas-upnp-org:service:AVTransport') >= 0) {
        const m = svc.match(/<controlURL>([\s\S]*?)<\/controlURL>/i);
        if (m !== null && m.length >= 2 && m[1].trim() !== '') {
          controlUrl = m[1].trim();
        }
      }
      // RenderingControl 服务：远程调电视音量用，有就顺手记下
      if (volumeUrl === '' && svc.indexOf('urn:schemas-upnp-org:service:RenderingControl') >= 0) {
        const m2 = svc.match(/<controlURL>([\s\S]*?)<\/controlURL>/i);
        if (m2 !== null && m2.length >= 2 && m2[1].trim() !== '') {
          volumeUrl = m2[1].trim();
        }
      }
    }
    if (controlUrl === '') {
      // 只提供 RenderingControl（纯音量控制）之类的设备，推不了视频
      return null;
    }
    const nm = xml.match(/<friendlyName>([\s\S]*?)<\/friendlyName>/i);
    let name: string = nm !== null && nm.length >= 2 ? decodeXmlEntities(nm[1].trim()) : '';
    if (name === '') {
      name = hostOf(location);
    }
    return new DlnaDevice(name, location, resolveUrl(location, controlUrl),
      volumeUrl !== '' ? resolveUrl(location, volumeUrl) : '');
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}

/** 一路 DLNA 投屏会话：持有电视 AVTransport 的控制地址，负责推流与播控 */
export class DlnaCast {
  private controlUrl: string;
  private volumeUrl: string;
  private deviceName: string;

  constructor(device: DlnaDevice) {
    this.controlUrl = device.controlUrl;
    this.volumeUrl = device.volumeUrl;
    this.deviceName = device.name;
  }

  /** 电视是否支持远程音量控制（设备描述里带 RenderingControl 服务才有） */
  hasVolumeControl(): boolean {
    return this.volumeUrl !== '';
  }

  /** 读电视当前音量（0-100）；不支持 / 读失败返回 -1 */
  async getVolume(): Promise<number> {
    if (this.volumeUrl === '') {
      return -1;
    }
    try {
      const text: string = await DlnaCast.postSoap(this.volumeUrl,
        'urn:schemas-upnp-org:service:RenderingControl:1', 'GetVolume',
        '<u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">' +
        '<InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolume>');
      const m = text.match(/<CurrentVolume>([^<]*)<\/CurrentVolume>/i);
      if (m === null || m.length < 2) {
        return -1;
      }
      const v: number = Number(m[1].trim());
      if (Number.isNaN(v) || v < 0) {
        return -1;
      }
      return Math.min(100, Math.floor(v));
    } catch (e) {
      // 有些电视实现了服务但不回应 GetVolume，当「读不到」处理
      return -1;
    }
  }

  /** 调电视音量（0-100）：走 RenderingControl 的 SetVolume（Master 声道） */
  async setVolume(volume: number): Promise<void> {
    if (this.volumeUrl === '') {
      throw new Error('volume control unsupported');
    }
    const v: number = Math.max(0, Math.min(100, Math.floor(volume)));
    await DlnaCast.postSoap(this.volumeUrl,
      'urn:schemas-upnp-org:service:RenderingControl:1', 'SetVolume',
      '<u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">' +
      '<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>' + v + '</DesiredVolume></u:SetVolume>');
  }

  /** 推流并起播：SetAVTransportURI → Play（→ 需要续播时再 Seek） */
  async setUriAndPlay(url: string, title: string, startSec: number): Promise<void> {
    const meta: string = DlnaCast.buildDidl(url, title);
    const inner: string =
      '<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">' +
      '<InstanceID>0</InstanceID>' +
      '<CurrentURI>' + escapeXml(url) + '</CurrentURI>' +
      '<CurrentURIMetaData>' + escapeXml(meta) + '</CurrentURIMetaData>' +
      '</u:SetAVTransportURI>';
    try {
      await this.soap('SetAVTransportURI', inner);
    } catch (e) {
      // 有些渲染器要求先 Stop 才能换 URI（电视上正在播别的内容时）
      try {
        await this.soap('Stop',
          '<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Stop>');
      } catch (e2) {
        // 原本就停着的话有些设备会报 701，无视
      }
      await this.soap('SetAVTransportURI', inner);
    }
    await this.soap('Play',
      '<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>');
    if (startSec > 5) {
      try {
        await this.seek(startSec);
      } catch (e) {
        // 续播定位失败就让电视从头放，不影响投屏本身
      }
    }
  }

  async play(): Promise<void> {
    await this.soap('Play',
      '<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>');
  }

  async pause(): Promise<void> {
    await this.soap('Pause',
      '<u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Pause>');
  }

  async stop(): Promise<void> {
    await this.soap('Stop',
      '<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Stop>');
  }

  /** 相对定位（从片头算起的秒数） */
  async seek(sec: number): Promise<void> {
    await this.soap('Seek',
      '<u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">' +
      '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>' + toHms(sec) + '</Target></u:Seek>');
  }

  /** 查询电视端进度：轮询历史续播、进度条、播完自动连播都靠它 */
  async getPosition(): Promise<DlnaPosition | null> {
    const text: string = await this.soapForText('GetPositionInfo',
      '<u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetPositionInfo>');
    const rt = text.match(/<RelTime>([^<]*)<\/RelTime>/i);
    const td = text.match(/<TrackDuration>([^<]*)<\/TrackDuration>/i);
    const posSec: number = rt !== null && rt.length >= 2 ? parseHms(rt[1]) : -1;
    const durSec: number = td !== null && td.length >= 2 ? parseHms(td[1]) : -1;
    if (posSec < 0) {
      return null;
    }
    return new DlnaPosition(posSec, durSec < 0 ? 0 : durSec);
  }

  /**
   * 查电视端真实传输状态（GetTransportInfo）：
   * PLAYING / PAUSED_PLAYBACK / STOPPED / TRANSITIONING / NO_MEDIA_PRESENT。
   * 电视可能被它自己的遥控器或系统播控中心暂停/停止，手机端记的状态会漂；
   * 播放/暂停按钮按下前先问一次，才不会「按了没反应」或「越按越反」。
   */
  async getTransportState(): Promise<string> {
    const text: string = await this.soapForText('GetTransportInfo',
      '<u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">' +
      '<InstanceID>0</InstanceID></u:GetTransportInfo>');
    const m = text.match(/<CurrentTransportState>([^<]*)<\/CurrentTransportState>/i);
    if (m === null || m.length < 2) {
      return 'UNKNOWN';
    }
    return m[1].trim().toUpperCase();
  }

  private async soap(action: string, inner: string): Promise<void> {
    await this.soapForText(action, inner);
  }

  /** 发一条 SOAP 控制指令（UPnP AVTransport:1），失败抛错由调用方决定怎么收场 */
  private async soapForText(action: string, inner: string): Promise<string> {
    return DlnaCast.postSoap(this.controlUrl, 'urn:schemas-upnp-org:service:AVTransport:1', action, inner);
  }

  /**
   * 发一条 UPnP SOAP 指令并返回响应文本。
   * 抽成静态公共出口：AVTransport（推流/播控）和 RenderingControl（音量）
   * 是两个不同的服务地址 + 服务 URN，只有信封和 HTTP 部分是共用的。
   */
  private static async postSoap(url: string, serviceUrn: string, action: string, inner: string): Promise<string> {
    const body: string = '<?xml version="1.0" encoding="utf-8"?>' +
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' +
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">' +
      '<s:Body>' + inner + '</s:Body></s:Envelope>';
    const client: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPACTION': '"' + serviceUrn + '#' + action + '"'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body,
        connectTimeout: 5000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING
      };
      const resp = await client.request(url, options);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error('SOAP ' + action + ' HTTP ' + resp.responseCode);
      }
      if (typeof resp.result === 'string') {
        return resp.result;
      }
      return '';
    } finally {
      client.destroy();
    }
  }

  /** DIDL-Lite 元数据：电视上显示片名用；res 里的地址就是电视要去拉的流 */
  private static buildDidl(url: string, title: string): string {
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/" ' +
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">' +
      '<item id="1" parentID="-1" restricted="1">' +
      '<dc:title>' + escapeXml(title) + '</dc:title>' +
      '<upnp:class>object.item.videoItem</upnp:class>' +
      '<res protocolInfo="http-get:*:*:*">' + escapeXml(url) + '</res>' +
      '</item></DIDL-Lite>';
  }
}

/** ArrayBuffer → 字符串（按单字节解码）。SSDP 应答头全是 ASCII，够用 */
function latinDecode(buf: ArrayBuffer): string {
  const bytes: Uint8Array = new Uint8Array(buf);
  let out: string = '';
  let chunk: string = '';
  for (let i = 0; i < bytes.length; i++) {
    chunk += String.fromCharCode(bytes[i]);
    if (chunk.length >= 512) {
      out += chunk;
      chunk = '';
    }
  }
  return out + chunk;
}

/** 字符串 → 字节（ASCII）。M-SEARCH 报文不含多字节字符 */
function encodeLatin(s: string): Uint8Array {
  const arr: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    arr[i] = s.charCodeAt(i) & 0xFF;
  }
  return arr;
}

/** 设备描述里的 controlURL 可能是绝对路径也可能带全 URL，统一拼成绝对地址 */
function resolveUrl(base: string, rel: string): string {
  if (rel.startsWith('http://') || rel.startsWith('https://')) {
    return rel;
  }
  const schemeEnd: number = base.indexOf('://');
  if (schemeEnd < 0) {
    return rel;
  }
  const pathStart: number = base.indexOf('/', schemeEnd + 3);
  const origin: string = pathStart > 0 ? base.substring(0, pathStart) : base;
  if (rel.startsWith('/')) {
    return origin + rel;
  }
  return origin + '/' + rel;
}

function hostOf(url: string): string {
  const schemeEnd: number = url.indexOf('://');
  const rest: string = schemeEnd >= 0 ? url.substring(schemeEnd + 3) : url;
  const slash: number = rest.indexOf('/');
  const host: string = slash > 0 ? rest.substring(0, slash) : rest;
  const colon: number = host.indexOf(':');
  return colon > 0 ? host.substring(0, colon) : host;
}

function decodeXmlEntities(s: string): string {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'").replace(/&amp;/g, '&');
}

function escapeXml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

/** "H:MM:SS" → 秒；NOT_IMPLEMENTED / 空串等返回 -1 表示未知 */
function parseHms(text: string): number {
  const t: string = text.trim();
  if (t === '' || t === 'NOT_IMPLEMENTED') {
    return -1;
  }
  const parts: string[] = t.split(':');
  if (parts.length < 3) {
    return -1;
  }
  const h: number = Number(parts[0]);
  const m: number = Number(parts[1]);
  const sec: number = Number(parts[2]);
  if (Number.isNaN(h) || Number.isNaN(m) || Number.isNaN(sec)) {
    return -1;
  }
  return Math.floor(h) * 3600 + Math.floor(m) * 60 + Math.floor(sec);
}

function toHms(sec: number): string {
  const s: number = Math.max(0, Math.floor(sec));
  const h: number = Math.floor(s / 3600);
  const m: number = Math.floor((s % 3600) / 60);
  const r: number = s % 60;
  return h + ':' + pad2(m) + ':' + pad2(r);
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : n.toString();
}
