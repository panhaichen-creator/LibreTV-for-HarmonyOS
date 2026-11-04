/**
 * 网络图片组件
 *
 * 通过 HttpClient 携带 Referer / UA 等请求头下载图片字节，再解码为 PixelMap 显示，并做内存缓存。
 * 用于豆瓣等对 Referer 有校验的图床：ArkUI 的 Image(url) 无法设置请求头，
 * 直接加载豆瓣海报会被返回 HTTP 418（空图），表现为「推荐有标题但封面空白」。
 */

import { image } from '@kit.ImageKit';
import { ImageBytes } from '../common/ImageBytes';

/** 简单的 PixelMap 内存缓存（按「URL + 解码框」去重） */
class NetImageCache {
  private static readonly map: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private static readonly MAX: number = 240;

  static get(key: string): image.PixelMap | undefined {
    return NetImageCache.map.get(key);
  }

  static put(key: string, pm: image.PixelMap): void {
    if (NetImageCache.map.size >= NetImageCache.MAX) {
      NetImageCache.map.clear();
    }
    NetImageCache.map.set(key, pm);
  }
}

@Component
export struct NetImage {
  @Prop url: string = '';
  @Prop referer: string = '';
  /**
   * 解码框（像素上限），默认 480×720，对应竖版海报。
   *
   * 关键点：解码时按原图宽高比**等比缩进**这个框，而不是把框的宽高直接当目标尺寸。
   * 因为 DecodingOptions.desiredSize 的官方说明是「输出会被拉伸到指定尺寸」——
   * 它不保比例。台标多是方形/横向小图，塞进竖版框就会被拉成一条，
   * 再被 objectFit(Cover) 一裁，就成了「横着的一条扁图标」。
   *
   * 台标请传一个小方形框（如 200×200）：既保比例，又不会为一张 40vp 的小图
   * 解码出 480×720 的像素图（后者约 1.35 MB/张，上百个频道能吃掉几百 MB）。
   */
  @Prop boxWidth: number = 480;
  @Prop boxHeight: number = 720;
  /** 填充方式。海报默认 Cover（裁边、不留空）；台标传 Contain，完整显示不变形 */
  @Prop fit: ImageFit = ImageFit.Cover;
  @State pm: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.loadImage();
  }

  /**
   * 算解码尺寸：保持原图比例，等比缩进 boxWidth×boxHeight。
   * 原图本身没超框时返回 undefined（按原尺寸解码，省掉一次无意义的重采样）。
   */
  private async decodeSizeFor(src: image.ImageSource): Promise<image.Size | undefined> {
    let w: number = 0;
    let h: number = 0;
    try {
      const info: image.ImageInfo = await src.getImageInfo();
      w = info.size.width;
      h = info.size.height;
    } catch (e) {
      return undefined;
    }
    if (w <= 0 || h <= 0) {
      return undefined;
    }
    // 传 0 表示该方向不设上限，用原图尺寸兜底
    const capW: number = this.boxWidth > 0 ? this.boxWidth : w;
    const capH: number = this.boxHeight > 0 ? this.boxHeight : h;
    if (w <= capW && h <= capH) {
      return undefined;
    }
    const k: number = Math.min(capW / w, capH / h);
    const size: image.Size = {
      width: Math.max(1, Math.round(w * k)),
      height: Math.max(1, Math.round(h * k))
    };
    return size;
  }

  /** 供外部在 URL 变化时刷新（父组件用 key 重建即可） */
  private async loadImage(): Promise<void> {
    const u = this.url;
    if (u === '') {
      return;
    }
    // 同一个 URL 可能被不同尺寸的调用方请求，缓存键要把解码框算进去
    const key: string = u + '|' + this.boxWidth + 'x' + this.boxHeight;
    const cached = NetImageCache.get(key);
    if (cached !== undefined) {
      this.pm = cached;
      return;
    }
    // 走共享字节缓存：与海报取色（PosterColor）复用同一份字节，
    // 同一张海报不会被下载两次。
    const buf: ArrayBuffer = await ImageBytes.fetch(u, this.referer);
    if (buf.byteLength === 0) {
      return;
    }
    try {
      const src = image.createImageSource(buf);
      // DecodingOptions 仅支持 desiredSize（Size{width,height}），无 desiredPixelWidth/Height
      const opts: image.DecodingOptions = {};
      const target: image.Size | undefined = await this.decodeSizeFor(src);
      if (target !== undefined) {
        opts.desiredSize = target;
      }
      const pm = await src.createPixelMap(opts);
      await src.release();
      NetImageCache.put(key, pm);
      this.pm = pm;
    } catch (e) {
      // 解码失败：保持占位底色
    }
  }

  build() {
    Stack() {
      // 不再画内部占位底色：Contain 模式下图片四周会露出这层底色，
      // 把父容器给的底板整个盖掉（台标换成深色底板时就是这么「失效」的）。
      // 需要底色的地方由父容器的 backgroundColor 负责。
      if (this.pm !== undefined) {
        Image(this.pm)
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
          .interpolation(ImageInterpolation.Medium)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
