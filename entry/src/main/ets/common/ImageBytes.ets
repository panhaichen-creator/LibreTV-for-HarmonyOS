/**
 * 图片字节共享缓存
 *
 * 背景：方案 B「光从内容来」需要拿到海报的主色。主色有两种取法：
 *   1. 再下一次图片 → 同一张海报被抓两遍，白白浪费流量；
 *   2. 复用 NetImage 已经下载的字节 → 但 NetImage 与取色逻辑分属两个组件，
 *      彼此拿不到对方手里的数据。
 *
 * 这里把「按 URL 取字节」抽成唯一入口，并同时做两件事：
 *   · pending 表：同一个 URL 并发请求只发一次（Promise 级去重）；
 *   · bytes 表：取过一次就留着，取色时不必重新下载。
 *
 * 字节缓存有上限（一张海报 100~400 KB），超过就整体清空，
 * 与 NetImage 的 PixelMap 缓存同样的取舍策略。
 */

import { HttpClient } from '../net/HttpClient';

/** 按图片域名推断所需 Referer（豆瓣图床会校验） */
export function refererFor(url: string): string {
  if (url.indexOf('doubanio.com') >= 0 || url.indexOf('douban.com') >= 0) {
    return 'https://movie.douban.com/';
  }
  return '';
}

export class ImageBytes {
  /** URL → 下载中的 Promise（并发去重） */
  private static pending: Map<string, Promise<ArrayBuffer>> = new Map<string, Promise<ArrayBuffer>>();
  /** URL → 字节（取色复用，避免二次下载） */
  private static cached: Map<string, ArrayBuffer> = new Map<string, ArrayBuffer>();
  private static readonly MAX: number = 24;

  /**
   * 取图片字节。
   * @param url 图片地址
   * @param referer 自定义 Referer，留空则按域名推断
   * @returns 字节缓冲；失败返回长度为 0 的缓冲（不抛异常）
   */
  static async fetch(url: string, referer: string = ''): Promise<ArrayBuffer> {
    if (url === '') {
      return new ArrayBuffer(0);
    }
    const hit: ArrayBuffer | undefined = ImageBytes.cached.get(url);
    if (hit !== undefined) {
      return hit;
    }
    const inflight: Promise<ArrayBuffer> | undefined = ImageBytes.pending.get(url);
    if (inflight !== undefined) {
      return await inflight;
    }
    const task: Promise<ArrayBuffer> = ImageBytes.download(url, referer);
    ImageBytes.pending.set(url, task);
    try {
      const buf: ArrayBuffer = await task;
      if (buf.byteLength > 0) {
        if (ImageBytes.cached.size >= ImageBytes.MAX) {
          ImageBytes.cached.clear();
        }
        ImageBytes.cached.set(url, buf);
      }
      return buf;
    } finally {
      ImageBytes.pending.delete(url);
    }
  }

  private static async download(url: string, referer: string): Promise<ArrayBuffer> {
    try {
      const headers: Record<string, string> = { 'User-Agent': HttpClient.UA };
      const ref: string = referer !== '' ? referer : refererFor(url);
      if (ref !== '') {
        headers['Referer'] = ref;
      }
      const res = await HttpClient.getBytes(url, headers, 12000);
      if (!res.ok || res.bytes.length === 0) {
        return new ArrayBuffer(0);
      }
      return res.bytes.buffer as ArrayBuffer;
    } catch (e) {
      return new ArrayBuffer(0);
    }
  }
}
