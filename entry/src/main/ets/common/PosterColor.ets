/**
 * 海报主色采样（方案 B「光从内容来」）
 *
 * 思路：推荐区的环境光不再由页面级的固定色斑决定，而是由「这片封面本身的主色」决定 ——
 * 冷调片子自带冷光，暖调片子自带暖光，光从内容来。
 *
 * 做法：
 *   1. 复用 ImageBytes 的字节缓存（同一张海报不会被下载两次）；
 *   2. 把海报缩到 8×8 解码 —— 尺寸小到可以忽略，颜色信息却足够；
 *   3. 读回像素，跳过近白 / 近黑 / 低饱和的像素（这些是背景与字幕，不是主色），
 *      把剩下的按 RGB 分桶取众数，再对众数桶内的像素求均值。
 *
 * 结果按 URL 缓存，避免同一张封面反复采样。
 */

import { image } from '@kit.ImageKit';
import { ImageBytes } from './ImageBytes';

/** 采样结果缓存：URL → '#RRGGBB' */
class PosterColorCache {
  private static readonly map: Map<string, string> = new Map<string, string>();
  private static readonly MAX: number = 160;

  static get(url: string): string | undefined {
    return PosterColorCache.map.get(url);
  }

  static put(url: string, color: string): void {
    if (PosterColorCache.map.size >= PosterColorCache.MAX) {
      PosterColorCache.map.clear();
    }
    PosterColorCache.map.set(url, color);
  }
}

/** 一个颜色桶：累加个数与通道和 */
class ColorBucket {
  count: number = 0;
  r: number = 0;
  g: number = 0;
  b: number = 0;
}

export class PosterColor {
  /** 采样尺寸：8×8 足够反映主色，又几乎不耗性能 */
  private static readonly SAMPLE: number = 8;
  /** 主色亮度下限（0~255）：低于这个值的光晕在深色页面上看不出来 */
  private static readonly MIN_LUMA: number = 132;

  /**
   * 取海报主色。
   * @param url 海报地址
   * @returns '#RRGGBB'；失败返回空串
   */
  static async dominant(url: string): Promise<string> {
    if (url === '') {
      return '';
    }
    const hit: string | undefined = PosterColorCache.get(url);
    if (hit !== undefined) {
      return hit;
    }
    const color: string = await PosterColor.sample(url);
    if (color !== '') {
      PosterColorCache.put(url, color);
    }
    return color;
  }

  private static async sample(url: string): Promise<string> {
    const buf: ArrayBuffer = await ImageBytes.fetch(url);
    if (buf.byteLength === 0) {
      return '';
    }
    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    try {
      src = image.createImageSource(buf);
      const opts: image.DecodingOptions = {
        desiredSize: { width: PosterColor.SAMPLE, height: PosterColor.SAMPLE },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      pm = await src.createPixelMap(opts);
      const bytes: number = pm.getPixelBytesNumber();
      if (bytes <= 0) {
        return '';
      }
      const dst: ArrayBuffer = new ArrayBuffer(bytes);
      await pm.readPixelsToBuffer(dst);
      return PosterColor.pick(dst, bytes);
    } catch (e) {
      return '';
    } finally {
      if (pm !== undefined) {
        try {
          pm.release();
        } catch (e1) {
          // ignore
        }
      }
      if (src !== undefined) {
        try {
          await src.release();
        } catch (e2) {
          // ignore
        }
      }
    }
  }

  /** 从 RGBA 像素里挑出主色 */
  private static pick(dst: ArrayBuffer, bytes: number): string {
    const u8: Uint8Array = new Uint8Array(dst);
    const buckets: Map<number, ColorBucket> = new Map<number, ColorBucket>();
    let fallbackR: number = 0;
    let fallbackG: number = 0;
    let fallbackB: number = 0;
    let fallbackN: number = 0;

    for (let i: number = 0; i + 3 < bytes && i + 3 < u8.length; i += 4) {
      const r: number = u8[i];
      const g: number = u8[i + 1];
      const b: number = u8[i + 2];
      const a: number = u8[i + 3];

      fallbackR += r;
      fallbackG += g;
      fallbackB += b;
      fallbackN += 1;

      if (a < 128) {
        continue;
      }
      const max: number = Math.max(r, Math.max(g, b));
      const min: number = Math.min(r, Math.min(g, b));
      // 近白 / 近黑直接跳过：海报的留白和黑边不是主色
      if (max > 238 && min > 210) {
        continue;
      }
      // 暗像素（阴影、黑边、夜景）一律不当主色。
      // 早先只挡了 max < 26 的纯黑，结果暗调海报选出来的「主色」本身就是黑的，
      // 洒出来的光和投影肉眼几乎看不见 —— 表现就是「有些封面没有发光」。
      if (max < 96) {
        continue;
      }
      // 低饱和（灰）也不做主色：灰光晕没有氛围感
      if (max > 0 && (max - min) / max < 0.18) {
        continue;
      }
      // 亮度太高的（接近纯白）再筛一次
      if (min > 200) {
        continue;
      }
      // RGB 各按 16 级分桶
      const key: number = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      let bucket: ColorBucket | undefined = buckets.get(key);
      if (bucket === undefined) {
        bucket = new ColorBucket();
        buckets.set(key, bucket);
      }
      bucket.count += 1;
      bucket.r += r;
      bucket.g += g;
      bucket.b += b;
    }

    if (buckets.size === 0) {
      // 全是灰 / 黑白的封面：退回到整体均值，至少不会给出一坨脏色
      if (fallbackN === 0) {
        return '';
      }
      return PosterColor.brighten(
        Math.round(fallbackR / fallbackN),
        Math.round(fallbackG / fallbackN),
        Math.round(fallbackB / fallbackN)
      );
    }

    let best: ColorBucket | undefined = undefined;
    buckets.forEach((bucket: ColorBucket) => {
      if (best === undefined || bucket.count > best.count) {
        best = bucket;
      }
    });
    if (best === undefined) {
      return '';
    }
    const win: ColorBucket = best;
    return PosterColor.brighten(
      Math.round(win.r / win.count),
      Math.round(win.g / win.count),
      Math.round(win.b / win.count)
    );
  }

  /**
   * 给主色兜一个亮度下限。
   *
   * 即使过滤掉了暗像素，众数桶仍可能是个中间调的深色（暗调海报里最"亮"的那块
   * 也可能只有 80/255）。这种颜色拿去做光晕和投影，在深色页面上等于没有。
   * 这里按亮度等比放大到 MIN_LUMA，色相不变 —— 冷调还是冷调，只是够亮了。
   */
  private static brighten(r: number, g: number, b: number): string {
    const luma: number = 0.299 * r + 0.587 * g + 0.114 * b;
    if (luma >= PosterColor.MIN_LUMA || luma <= 0) {
      return PosterColor.toHex(r, g, b);
    }
    const k: number = PosterColor.MIN_LUMA / luma;
    return PosterColor.toHex(
      Math.round(r * k),
      Math.round(g * k),
      Math.round(b * k)
    );
  }

  private static toHex(r: number, g: number, b: number): string {
    const rr: number = Math.max(0, Math.min(255, r));
    const gg: number = Math.max(0, Math.min(255, g));
    const bb: number = Math.max(0, Math.min(255, b));
    return '#' + PosterColor.hex2(rr) + PosterColor.hex2(gg) + PosterColor.hex2(bb);
  }

  private static hex2(v: number): string {
    const s: string = v.toString(16).toUpperCase();
    return s.length === 1 ? '0' + s : s;
  }
}
