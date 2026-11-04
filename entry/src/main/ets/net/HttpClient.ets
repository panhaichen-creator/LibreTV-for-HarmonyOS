/**
 * HTTP 客户端：基于 @kit.NetworkKit 的 http 模块封装
 * - 每个请求独立 createHttp / destroy
 * - 支持自定义请求头（UA / Referer / Cookie）
 * - 自动识别并解压 gzip 响应
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Gzip } from '../common/Gzip';

export interface HttpResult {
  ok: boolean;
  status: number;
  text: string;
  bytes: Uint8Array;
  error: string;
}

export class HttpClient {
  static readonly UA: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  /** 采集站通用请求头（与 LibreTV cmsRequestHeaders 对齐） */
  static cmsHeaders(): Record<string, string> {
    return {
      'User-Agent': HttpClient.UA,
      'Accept': 'application/json'
    };
  }

  static async getText(url: string, headers: Record<string, string> = {}, timeoutMs: number = 10000): Promise<HttpResult> {
    return await HttpClient.get(url, headers, timeoutMs, false);
  }

  /**
   * 拉取 m3u8 / 静态资源用的容错请求。
   * 大量播放 CDN 按 Referer 做防盗链：带上它自己域名的 Referer 反而被判成盗链返回 403。
   * 这里按「带 Referer → 只带 UA → 极简头」逐级放宽重试，尽量拿到真实内容。
   */
  static async getTextResilient(url: string, timeoutMs: number = 12000): Promise<HttpResult> {
    const referer: string = HttpClient.originOf(url);
    const variants: Record<string, string>[] = [
      { 'User-Agent': HttpClient.UA, 'Referer': referer },
      { 'User-Agent': HttpClient.UA },
      { 'Accept': '*/*' }
    ];
    let last: HttpResult = await HttpClient.getText(url, variants[0], timeoutMs);
    if (last.ok && last.text !== '') {
      return last;
    }
    for (let i = 1; i < variants.length; i++) {
      const r: HttpResult = await HttpClient.getText(url, variants[i], timeoutMs);
      if (r.ok && r.text !== '') {
        return r;
      }
      last = r;
    }
    return last;
  }

  /**
   * 文本拉取：http(s) 走网络，file:// 读本地沙箱文件（本地导入的播放列表）。
   */
  static async getTextAny(url: string, headers: Record<string, string> = {}, timeoutMs: number = 10000): Promise<HttpResult> {
    if (url.startsWith('file://')) {
      const text = await HttpClient.readLocalText(url);
      const ok = text !== '';
      return { ok: ok, status: ok ? 200 : 0, text: text, bytes: new Uint8Array(0), error: ok ? '' : '本地文件读取失败' };
    }
    return await HttpClient.getText(url, headers, timeoutMs);
  }

  /** 读取文本文件（沙箱绝对路径或 file:// / 文档 URI），UTF-8 解码 */
  static async readLocalText(path: string): Promise<string> {
    let fd = -1;
    try {
      try {
        fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      } catch (e1) {
        // 沙箱绝对路径误带 file:// 前缀时剥掉重试
        if (path.startsWith('file://')) {
          fd = fs.openSync(path.substring(7), fs.OpenMode.READ_ONLY).fd;
        } else {
          return '';
        }
      }
      const stat = fs.statSync(fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(fd, buf);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } catch (e) {
      return '';
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (e2) {
          // ignore
        }
      }
    }
  }

  /** 取 url 的「协议 + 主机 + /」，用作默认 Referer */
  static originOf(url: string): string {
    const protoEnd: number = url.indexOf('://');
    if (protoEnd < 0) {
      return url;
    }
    const proto: string = url.substring(0, protoEnd + 3);
    const rest: string = url.substring(protoEnd + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
    return proto + host + '/';
  }

  static async getBytes(url: string, headers: Record<string, string> = {}, timeoutMs: number = 10000): Promise<HttpResult> {
    return await HttpClient.get(url, headers, timeoutMs, true);
  }

  private static async get(url: string, headers: Record<string, string>, timeoutMs: number, binary: boolean): Promise<HttpResult> {
    const httpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: binary ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING
      };
      const response = await httpRequest.request(url, options);
      let bytes = new Uint8Array(0);
      let text = '';
      const result = response.result;
      if (binary) {
        if (result instanceof ArrayBuffer) {
          bytes = new Uint8Array(result);
        }
      } else if (typeof result === 'string') {
        text = result;
      }
      // 自动解压 gzip（含 Content-Encoding: gzip 与 .gz 直链）
      if (bytes.length > 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) {
        try {
          bytes = Gzip.gunzip(bytes);
          text = Gzip.toText(bytes);
        } catch (e) {
          // 解压失败时保留原始字节
        }
      } else if (binary && bytes.length > 0 && text === '') {
        // 二进制模式（如 XMLTV 节目单）同时给出文本形式
        try {
          const decoder = util.TextDecoder.create('utf-8');
          const copy = bytes.slice();
          text = decoder.decodeToString(copy);
        } catch (e) {
          // ignore
        }
      }
      const ok = response.responseCode >= 200 && response.responseCode < 300;
      return { ok, status: response.responseCode, text, bytes, error: ok ? '' : 'HTTP ' + response.responseCode };
    } catch (e) {
      const err = e as BusinessError;
      return { ok: false, status: 0, text: '', bytes: new Uint8Array(0), error: err.message ?? 'network error' };
    } finally {
      httpRequest.destroy();
    }
  }
}
